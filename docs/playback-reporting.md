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
  carry item ID, position and playback state, never stream URLs. The negotiated
  source's MediaSourceId and server PlaySessionId are retained when available;
  otherwise PlaySessionId uses the reporting occurrence UUID. Negotiated AAC HLS
  reports Transcode; copy HLS reports DirectStream. Unknown delivery omits
  PlayMethod instead of guessing. The local occurrence identity still separates
  event lifetimes even when a server-negotiated identifier is supplied.

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

## v0.6 source audit and physical acceptance packet — 2026-10-27

Audited local integration base `88aea11d3af780f5cfebada0488f9a0b970c9f78`.
This is source evidence, not a fresh executed test or live-server result. The
remaining owner observation in #154 is not resolved by this audit.

| Production boundary | Current behavior / existing regression seam |
| --- | --- |
| Native commitment | `FoundationPlayer.refreshNativeState` begins only at native playing; existing reporting tests cover rejected starts and actual muted native commitment. |
| Pause/resume/seek | Same occurrence; state transitions and successful seek completion bypass the periodic throttle. Existing owner tests cover ordering/throttling; actual device/server outcomes remain pending. |
| Repeat/duplicates/end/replacement | Fresh reporting occurrence after selection retirement, ordered stop/start; existing native repeat-one and delayed owner tests cover this seam. |
| Bounds/failure | One send plus 32 pending, ten-second periodic progress, per-occurrence coalescing, reserved stop capacity; failures are dropped without retries. Production URLSession has 30-second request/60-second resource timeouts. |
| Account/connectivity | Sign-out stops playback then invalidates reporting; a final queued stop may be cancelled during that cleanup. Offline transition discards pending work without backfill. Already-sent server effects cannot be undone by local cancellation. |
| Adapter | Official Start/Progress/Stopped POSTs, validated IDs/finite positions, 100 ns position ticks; POSTs bypass optional catalog GET admission. Existing adapter tests verify paths/body and rejection before transport. |

Home uses the existing account-owned history cache and visible refresh mechanism:
one 24-song page for each initial/refresh attempt, with a 60-second refresh interval
while the shelf is active, visible and foreground. View disappearance/background
or local-only mode cancels that task. A failed attempt ends automatic refresh;
explicit pull-to-refresh or successful connectivity retry starts a new attempt.
Other visible Home shelves have their own existing bounded page reads; 24 is the
history-page size, not the total Home request budget. Reporting adds no polling
or reporting-success-triggered refresh. This existing general cache refresh is
periodic; it must not be described as absence of all polling. The release owner
must assess it against #154's no-polling-to-force-history criterion.

For the server reference, Jellyfin v10.11.6
[SessionManager.OnPlaybackStart](https://github.com/jellyfin/jellyfin/blob/v10.11.6/Emby.Server.Implementations/Session/SessionManager.cs#L752)
updates play count and last-played date. Its stop path applies the server's play
state rules. Capture the actual server version before choosing expected results;
proposed or later server changes do not establish this installation's behavior.
The app's Recently Played query additionally requires IsPlayed and sorts by
DatePlayed, so session activity, last-played date, play count and visible history
must be observed separately.

Execute the following only in the coordinator's authorized device/server lane,
against an exact installed candidate and a sanctioned test account/library. Use
synthetic or disposable tracks when available; playback intentionally updates
listening history. Do not reset real play counts or fabricate played flags.
Use aliases A/B in shared evidence; retain actual mapping only privately.

1. Record platform/build/source, server version, foreground/background state,
   debugger/Mirroring state, route, and baseline play-count/played/date fields for
   A/B. Record whether the account can inspect active sessions; lack of that
   privilege is an unverified observation, not a client defect.
2. Play A for at least 25 seconds. Observe native audible start, server session
   activity and position. Compare baseline fields with the server's versioned
   semantics. With no other transitions, progress is at most one report per ten
   seconds; do not infer exact POST counts from a progressing session timer.
3. Pause, wait, resume, seek forward and backward, then stop. Verify server paused
   state/position and ordered termination, with audible recovery. Position seeks
   do not prove that intervening audio was listened to.
4. Queue A/A/B, rapidly skip one occurrence, then repeat one occurrence once and
   disable repeat. Verify distinct start/stop lifetimes and actual final server
   state without expecting a guaranteed count for an uncommitted skipped item.
5. Let one track finish naturally and advance while another app is foreground;
   observe audio and server progression, then return to Home. Compare the raw
   server fields/query with one explicit app refresh, separating stale cache from
   absent reports or the server's IsPlayed filtering.
6. In the sanctioned environment, fail a reporting request while audio remains
   reachable. Verify that audio and the next explicit action remain usable, there
   is no retry cascade, and a later distinct occurrence can report. If the failure
   cannot be isolated safely, mark this row pending instead of disconnecting a
   production server or assuming a synthetic test proves it physically.
7. Separately verify local-only playback creates no queued/backfilled history;
   reconnect, explicitly start a new occurrence, then verify reporting resumes.
   Test sign-out only after preserving the account's recoverable state and using
   the established acceptance procedure; no credential cleanup is authorized by
   this packet.

Store aggregate per-step pass/fail/pending, request-kind counts where actually
observed, user-confirmed audible outcome and field deltas. Shared evidence excludes
server origins, tokens/headers, account/item/session IDs, media names, complete
request bodies and raw server logs. No listening-history deletion or reset is
needed to finish this matrix. The issue remains open until the physical/server
criteria and any demonstrated corrections are accepted.
