# 0004 — Source adapters and local-file playback

- Status: Accepted
- Date: 2026-07-29

## Context

Velacanto needs one playback experience for music that may originate from
Jellyfin, Navidrome, a file selected on the device, or a future service. Tying
the player directly to a Jellyfin endpoint would duplicate transport controls
and platform-media integration as more sources are added.

Privacy-focused users also need a path that does not require a server account
or uploading a personal library into the app.

## Decision

- Keep source resolution behind `PlaybackSourceAdapter`.
- Make source resolution asynchronous so an adapter can perform provider-specific
  playback-info work without changing the coordinator contract.
- Have each adapter produce a provider-neutral `PlaybackRequest` containing
  display metadata, an open-ended source identifier, an opaque resource lease,
  and a main-actor factory for the `AVPlayerItem` that AVFoundation should play.
- Use one `AudioPlaybackCoordinator` and one injectable AVFoundation engine for
  local and remote assets.
- Drive coordinator state from AVFoundation readiness, time-control, completion,
  stall, and failure events rather than treating a play command as proof that
  media is playing.
- Implement Local Files first. It passes the selected file URL through
  unchanged and retains its security-scoped permission only while that item is
  active.
- Do not copy, import, index, upload, or create a persistent bookmark for a
  user-selected file.
- Keep Jellyfin as the primary 0.1.0 server integration. Reserve Navidrome as a
  distinct adapter so its authentication and API behavior do not leak into the
  shared player.
- Keep an app-generated tone as a diagnostic path. It is written only to
  the temporary directory and is not user library content.

## Consequences

- Local playback can validate the shared AVFoundation path before server
  connectivity and the iOS simulator are ready.
- Jellyfin, Navidrome, and future sources can share play, pause, seek, timing,
  audio-session, and system-media behavior.
- Providers can perform asynchronous resolution or customize player-item
  construction without exposing credentials or transport details to the
  coordinator.
- Deterministic engine tests can exercise waiting, playing, pause, completion,
  failure, seeking, and resource-lifetime policy without a live audio session.
- Local file access ends when playback stops, another item replaces it, or the
  app terminates. Navigating away from the current view does not stop active
  playback.
- Library browsing remains source-specific; this ADR standardizes playback
  handoff rather than forcing unlike server APIs into one implementation.
- Restoring a local file after relaunch would require a separate explicit
  persistent-access decision. The current prototype intentionally does not do
  that.
