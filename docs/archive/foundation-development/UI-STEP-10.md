# Reduced Now Playing comparison

Base90b9e586db7b712f4516d04d956f3632c9357ea0, failed candidate10 preserved.
Owner reports initial playback worked, followed by lyrics/queue/destination
navigation and rapid skips, then device-wide connectivity failure. Saved journal
shows initial readiness, three rapid skip selections, final native item timeout,
and later artwork network failure. This does not prove the initiating cause.

Owner-directed deletion: lyrics sheet/API/types, native volume/AirPlay adapters,
Now Playing favorite/overflow/destination state, unused artist reference mapping.
Retain full sheet, album art/title/artist text, basic controls including native
seek, and queue occurrence actions. No player/transport/session/journal change.
One existing bounded artwork request per visible album/tag remains. Text metadata
uses existing catalog response; queue opening has zero metadata requests.

No added dependencies/tests/diagnostic or recovery framework. Existing tests and
platform gates run; exact results belong to artifact11 record. Device validation
must begin after connectivity from prior failure is restored. First test play,
skip forward/back, queue selection and return to the sheet; then scrub. Keep
features removed until the owner accepts the reduced build. Do not infer a root
cause from one successful comparison or claim repaired network reliability.
