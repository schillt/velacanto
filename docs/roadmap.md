# Velacanto roadmap

## Current release: 0.2

0.1.0 is the completed listening-path baseline. The active 0.2 release is a
small, disciplined UI architecture and interface-quality pass; its complete
scope, guardrails, and exit criteria live in the [0.2 plan](0.2-plan.md).

| Priority | Work | Tracking |
| --- | --- | --- |
| Required | Separate UI ownership and remove catalog duplication | #33, #35 |
| Required | Make persistence/cache/reporting failures diagnosable; document contracts | #36, #37 |
| Required | Fix sidebar, artwork sizing, and Now Playing overlap defects | #40, #42, #45 |
| Conditional | Play/Shuffle entry points, macOS playlist section, directly relevant API simplification | #43, #44, #34 |
| Deferred | Favorites, editable playlists/queues, playback-mode indicator, search tolerance, and playback polish | #11, #12, #41, #46, #47 |

## Release history

### 0.1.0 — complete

The 0.1 release established native iOS and macOS surfaces, secure Jellyfin
connection and session handling, browsing/search, local and Jellyfin playback,
background audio, system-media controls, and a repeatable quality gate. Its
historical scope and recorded device/server evidence remain in
[the 0.1 plan](0.1-plan.md) and [stability acceptance](0.1-stability-acceptance.md).

## Later direction

The following are intentionally not scheduled into 0.2:

- Favorites and editable playlists/queues.
- Offline downloads, artwork-storage controls, and network-transition work.
- CarPlay and casting.
- Multiple accounts, richer metadata, explicit transcoding controls, and
  Navidrome/Subsonic support.
- Public distribution and App Store release automation.

Each later milestone must be scoped from the state reached at the end of the
previous release, rather than from the provisional weekly dates established
during the 0.1 prototype.
