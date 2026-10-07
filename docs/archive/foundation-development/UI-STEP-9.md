# Full Now Playing

Base: 9e3744f68319a0899a4e10ed88558f092938d947, owner-tested Home candidate09.
Source branch codex/foundation-now-playing preserves the local tested lineage.
Original Now Playing was inspected live in the simulator this step: artwork,
track/artist/album labels, favorite/overflow, scrubber, transport, volume and
AirPlay/lyrics/queue controls. Rebuilt using native SwiftUI and AVKit/MediaPlayer,
not legacy controllers. No dependencies or test scaffolding added.

The previous combined player/queue List is replaced by the full page and a
separate queue sheet. Queue occurrence behavior remains unchanged. Native seek
occurs on completed scrub and checks the initiating occurrence before acting;
no completion handler, retry, replacement item, or playback lifecycle layer.

Catalog responses now supply optional neutral album/artist references and
request Primary image tags for tracks, including playlist tracks. No extra
metadata requests. Full-page album art: zero requests without a tag; one bounded
1024px JPEG read per new visible album/tag; same-album skip within the page reuses
the image. Reopening can read again using the existing native request path.
Lyrics: one explicit opening read, one per deliberate Retry, canceled on dismissal
or changed track. No prefetch, synchronization polling, remote lyric download
or automatic retry. Missing lyrics, album references or images remain local.
View Album/Artist reuses existing destinations, one bounded first page on cold
entry with explicit pagination. Queue opening/editing: zero metadata requests.

macOS volume controls the existing player volume; iOS uses system MPVolumeView.
Both use native AVRoutePickerView. Lyrics are scrollable text; synchronized lyric
tracking, shuffle/repeat and other playback features remain outside this step.

Existing image-flag assertions updated to match metadata changes. Actual final
compilation, existing test, Release exclusion, signature and installation results
are recorded with candidate10. Physical acceptance is owner-run; compilation
does not prove device behavior or reliability. No source promotion to alpha.
