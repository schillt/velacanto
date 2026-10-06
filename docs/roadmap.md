# Velacanto roadmap

GitHub issues, latest owner scope comments and the [Development Project](https://github.com/users/schillt/projects/1) control current work. This roadmap records direction, not implementation or acceptance. No future milestone has a committed date.

## Current checkpoint: 0.3.5 alpha

[0.3.5](https://github.com/schillt/velacanto/releases/tag/0.3.5) was published from alpha at `6efcd01d0526291c5f992d658a8d10ec93e5496d`; its exact post-merge [Quality Gate](https://github.com/schillt/velacanto/actions/runs/36362999380) passed. It includes native system commands, volume and AirPlay, shared current artwork, inline synchronized lyrics and playback handoff improvements. These are shipped alpha implementations with remaining physical/network/distribution limits in [#169](https://github.com/schillt/velacanto/issues/169). Main was not promoted.

Post-release alpha includes sign-out and pin cleanup at `88aa9f6588dcdc5487979036b60c450d2af220a5`. Integrated source is not a new release or proof of all privacy checks. The initial 0.4 planning base is `de7abe9df9ae294184cadbddb01ecc2161038ab1`; fetch current alpha before each assignment.

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
