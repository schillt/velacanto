# UI step 1: album-list artwork only

Base: f323f9757eb329d9166906b76304feaf54a09ceb, preserving the owner-tested
minimal player. The owner reports successful rapid skips, Previous, direct
queue selection and album switching; further interruption tests were deferred
at the owner's request. These observations do not establish outage recovery.

The only visible addition is a 52-point album thumbnail in the album browser.
The album page includes Primary image tags, then each row owns one tagged JPEG
request, requesting at most 160 pixels in each dimension. It uses the official
SDK's GetItemImage endpoint through the existing authenticated URLSession path.
No credential is added to an image URL. Redirect rejection, native deadlines,
cancellation and finite DEBUG diagnostic categories remain shared.

The response loader now returns bytes for either catalog decoding or images,
removing the need for a second transport/authentication implementation. No
player, queue or playback URL code changed. No artwork is added to Now Playing,
tracks, or the queue. No retries, prefetch loop, disk cache or connection manager
is introduced. Missing or failed art remains a local music-note placeholder.

Retained row images avoid rereads. Destroyed rows may request again; native List
can instantiate nearby rows. This step makes no persistent-cache or strict
visible-pixel request-budget claim. See CONTRACT.md for exact operation budgets.

## Verification

- Lint and diff checks passed.
- macOS Debug compiled; all 26 tests passed (11 API, 9 player, 6 presentation).
- Added checks cover tag hydration, bounded authenticated image requests,
  zero image requests for missing art/tracks, and image failure followed by
  catalog success without retry. Existing player/queue tests passed unchanged.
- UI appearance, physical scroll request counts, and scrolling with playback
  require owner testing on this signed candidate. No device test is claimed.

## Owner test

Open Albums, scroll covers, start an album, and repeat the rapid skips and queue
selections that passed previously. Return to Albums and scroll while playing.
Report any new delay, missing content or playback failure. We stop at this
single feature until that comparison is complete.

## Primary API reference

The pinned official Swift SDK defines GetItemImageAPI.swift. Jellyfin documents
image tags and image size bounds in its generated API:
https://typescript-sdk.jellyfin.org/interfaces/generated-client.ImageApiGetItemImageRequest.html

## Final local gates and limits

Release compilation and binary exclusion checks passed: no detailed journal,
synthetic launch flag, test class or legacy transport/player markers. Signed
iOS Debug compilation passed. Independent read-only review found no blocker.
DEBUG API outcome=success now describes successful HTTP response receipt; JSON
decoding follows separately and may still fail. Do not interpret this event as
proof of catalog publication or playback success.

Logs: archive-local/foundation-artwork-tests.log and tests.xcresult,
archive-local/foundation-artwork-release.log,
archive-local/foundation-artwork-signed.log,
archive-local/foundation-artwork-lint.log.
