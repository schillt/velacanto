# Playback reporting (#154)

This local implementation uses the existing account library adapter and player.
It does not replace playback transport or fabricate Recently Played/play counts.

## Event semantics

- Start is emitted only after the installed native item reaches `.playing`, never
  when selecting a queue row, resolving a URL, buffering, or requesting Play.
- Every native playback lifetime has a fresh opaque occurrence ID, including
  repeat-one and duplicate queue entries. Pause/resume retains that identity.
- Periodic progress is limited to once per 10 seconds of monotonic time while
  playback intent is active. Pause/resume and successful seek completion report
  state immediately; unsent progress for the same occurrence is coalesced.
- Replacement, stop, failure and accepted native end emit one terminal event with
  the current native position. Natural successors retain the existing player and
  resource handoff; reporting does not delay them.
- Reports use the official Jellyfin Start/Progress/Stopped SDK endpoints. They
  carry item ID, occurrence ID, position and playback state, never stream URLs.
  Delivery method is omitted because the adapter has not established whether
  Jellyfin selected direct delivery or transcoding.

## Bounds and account lifetime

One request is in flight per reporting owner; up to 32 events may wait. Each
admitted start reserves capacity for its terminal event. Saturation skips whole
new reporting occurrences rather than letting reporting block audio. Failed
requests are not retried. No report or event queue is written to disk.

Online playback from either a stream or ready download is eligible. A track begun
in local-only mode is not backfilled after reconnection. Going local-only drops
pending reports and requests cancellation of the active send. The occupied worker
slot is retained until that send finishes, even if cancellation is not cooperative.
Account replacement/cleanup invalidates the owner; late work cannot publish a new
account's events. Events lost to network failure, cancellation or saturation may
leave server history incomplete; there is no promise of exactly-once delivery.

## Home and acceptance

Reporting adds no Home refresh timer or callback. Existing visible cache refresh,
explicit refresh and bounded view loading continue to read server history; server responses
remain authoritative. Reporting success itself is not evidence that Jellyfin has
updated its history/play counts.

Deterministic tests cover ordering, throttling, saturation, delayed cancellation,
failed delivery, duplicate/repeated occurrences, rejected native starts and
actual native commitment using muted synthetic audio. Adapter tests check official
paths and request bodies. Physical server acceptance remains pending: rapid skips,
pause/resume, seek, completion, stop and sign-out on the exact installed artifact,
with server sessions/history/play-count observations and user-confirmed audio.
