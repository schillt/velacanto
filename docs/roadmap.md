# VelaCanto roadmap

Current scope comes from the owner's instructions, [live0.6 milestone](https://github.com/schillt/velacanto/milestone/9), issue contracts and [Development Project](https://github.com/users/schillt/projects/1). No future milestone has a committed date.

The installed local checkpoint is **0.6.0(233)** with runtime source in `5718da7`.
Read the [checkpoint](0.6.0-alpha-checkpoint.md), [all30 current issue statuses](0.6.0-issue-status.md)
and [agent handoff](0.6.0-agent-handoff.md). Source, scoped tests, local installation,
physical acceptance, publication and Apple distribution are separate states.

## Current0.6 work

- Complete playlist management/reorder and shared-feature/native UX parity on iOS/Mac.
- Accept CarPlay automatic Now Playing, supported audio-category browse/Siri and origin-aware exit flow. The navigation-only keyboard approach was removed; native acceptance remains.
- Finish shared bottom clearance/underlap, system-aware related/overview sheets, queue/lyrics, loading, favorites, metadata, genres and desktop interaction/scrolling.
- Finish native folder access and local/Jellyfin catalog composition acceptance. Resolve missing proposed Mac capabilities before claiming native folder access works.
- Complete cross-device continuation: native Handoff is installed with scoped positive owner feedback; the remote card's guide-preference failure remains. Browser continuation is a separate excluded prototype.
- Investigate system Settings storage management. Existing Profile bulk management remains until a proven supported replacement; isolated proof is not production functionality.
- Complete physical/server/network/account/privacy/accessibility and exact-candidate gates. Optional pin sync remains off/unconfigured; broader Siri scope and standalone-artist inclusion need explicit decisions.

All30 milestone issues remain open. The status matrix names evidence and next action
for each; an implementation estimate is not a release completion percentage.

## Later work and existing release gates

Token-bearing URL elimination #25 is explicitly0.7. Measured maintainability,
accessibility/performance and ownership/fixture refactors remain in their existing
later milestones. Additional casting #17 was declined and closed not-planned.
Other-provider scope is not restored by this roadmap.

Older0.5 distribution/provenance gates #63/#149/#169 remain separately open.
The installed development checkpoint establishes neither TestFlight availability
nor promotion readiness. No beta/main promotion, tag, upload or submission is
implied. Private Project fields remain unaudited with the current tool access;
reconcile them through an authenticated Project-capable session before claiming
board/release disposition complete. Detailed older records remain historical.
