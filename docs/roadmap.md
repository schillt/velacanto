# Velacanto roadmap

## Current release: 0.2.0

0.2.0 is the current release. It completes a small, disciplined UI architecture
and interface-quality pass over the 0.1 listening-path baseline. The completed
scope and validation record are in the [0.2 release notes](0.2-release-notes.md);
the original scope is retained in the [0.2 plan](0.2-plan.md).

## Release history

### 0.2.0 — current

The 0.2 release separates presentation ownership, removes duplicated catalog
and artwork behavior, fixes the targeted platform UI defects, and improves
persistence diagnostics. It also adds native Play/Shuffle entry points and a
macOS playlist section. See the [0.2 release notes](0.2-release-notes.md).

### 0.1.0 — complete

The 0.1 release established native iOS and macOS surfaces, secure Jellyfin
connection and session handling, browsing/search, local and Jellyfin playback,
background audio, system-media controls, and a repeatable quality gate. Its
historical scope and recorded device/server evidence remain in
[the 0.1 plan](0.1-plan.md) and [stability acceptance](0.1-stability-acceptance.md).

## Later direction

The following are intentionally not scheduled into the current release:

- Favorites and editable playlists/queues.
- Offline downloads, artwork-storage controls, and network-transition work.
- CarPlay and casting.
- Multiple accounts, richer metadata, explicit transcoding controls, and
  Navidrome/Subsonic support.
- Public distribution and App Store release automation.

Each later milestone must be scoped from the state reached at the end of the
previous release, rather than from the provisional weekly dates established
during the 0.1 prototype.
