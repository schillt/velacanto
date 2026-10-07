# Native player implementation

The player owns one AVPlayer for its lifetime. Every valid explicit selection
cancels its prior resolution task, advances a generation, pauses and detaches
the old item, cancels its pending seeks and asset loading, then resolves the
new selection. Silence between selections is intentional. Cancellation is
cooperative; a late completion must pass cancellation and generation checks
before creating or installing an AVPlayerItem. This is application ownership,
not a claim about native network cancellation drain.

Queue entries have fresh local UUID occurrence identity, including duplicates.
Only supplied tracks enter the queue. Invalid selection and Next/Previous at
boundaries do nothing. Previous selects the preceding occurrence regardless of
elapsed time. Native EOF advances one occurrence, with native item identity
rejecting stale notifications; the last item displays ended. Stop clears the native item but retains the selected occurrence and queue;
explicit Play resolves the selected occurrence afresh. Move/remove are omitted.

The published state follows native item/player failure and AVPlayer
timeControlStatus. A play command never directly publishes playing. Loading
means application URL resolution or native item readiness is unknown; waiting
means native waiting. Elapsed and
duration are native CMTime values, sanitized for indefinite/nonfinite values.
The native periodic observer updates the local UI only; it sends no reports.
A failure displays a fixed message; explicit queue selection or Play starts a
fresh resolution. No retries occur automatically. Pausing during resolution
prevents playback when the result arrives.

The playback audio-session category is configured and activated on an explicit
play or selected-item start. Interruption began pauses; resumption requires
explicit Play. No automatic resume policy or interruption recovery manager is
introduced. Stop deactivates the session with notifyOthersOnDeactivation.
Background capability and app lifecycle ownership belong to root integration.

## Apple primary sources and rationale

- [AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer):
  Apple documents reuse through replaceCurrentItem and one media asset at a time.
- [replaceCurrentItem(with:)](https://developer.apple.com/documentation/avfoundation/avplayer/replacecurrentitem(with:)):
  detach the previous item with nil before resolving its replacement.
- [timeControlStatus](https://developer.apple.com/documentation/avfoundation/avplayer/timecontrolstatus-swift.property):
  expose native paused, waiting and playing, not an optimistic command state.
- [AVPlayerItem status](https://developer.apple.com/documentation/avfoundation/avplayeritem/status-swift.property):
  observe native preparation failure without logging its error payload.
- [Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions):
  AVPlayer participates in audio-session interruptions; observe interruption
  began and require explicit user resumption in this minimal milestone.
- [Playback category](https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playback):
  use the documented music playback category; project enables background audio.
- [cancelLoading](https://developer.apple.com/documentation/avfoundation/avasset/cancelloading()):
  cancel asset loading when discarding an obsolete native item.

## Budget and privacy

Cold and warm explicit selection each call playbackURL at most once, plus
native media traffic. The API adapter owns whether resolution performs a
request or merely constructs its documented URL. Queue navigation never reads
catalog pages. Boundary/invalid navigation, pause and stop resolve zero URLs.
EOF resolves only the next existing occurrence. No queue expansion, prefetch,
admission, watchdog, deadline, retry or second player exists.

DEBUG journal calls record finite player state, item status, wait reason and
failure categories with ephemeral selection generations. No native errors,
URLs, credentials, media names or account identifiers are recorded.

## Verification and remaining gates

Nine player tests cover cancelled late resolution, replacement during load,
duplicate occurrences and boundaries, stop, explicit recovery, EOF identity,
pause during loading, honest loading state, and real native playback of a
generated silent WAV. Controlled continuations provide deterministic ordering;
the native test uses a bounded expectation. Tests disable account restore and
use no server or persisted credentials. The WAV test uses real AVPlayer.play;
other tests inject native operations where needed for deterministic ownership.

Root records combined execution results in BUILD-STATUS.md. These tests cannot
prove remote media readiness, native network cancellation drain, interruption
recovery, or physical-device reliability. Owner acceptance remains required.
