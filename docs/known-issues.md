# Velacanto known issues

This list describes limitations that remain after the 0.1 performance and
playback stabilization implementation. It is not a release-readiness statement.

- The Slice 1 connect, authenticate, relaunch, restore, and logout journey has
  been verified against a real Jellyfin server on a physical iPhone. The
  complete connect → browse → play journey still needs end-to-end validation on
  iOS and macOS.
- Universal audio streaming requests MP3 as the fallback transcode format.
  Direct-play and transcode behavior still need compatibility testing across
  common Jellyfin server versions and source codecs.
- AVPlayer receives a playback URL containing the Jellyfin access token as an
  API query parameter. Velacanto does not log that URL, but playback error
  review must continue to treat URLs as sensitive.
- A saved session remains available when launch-time validation fails because
  the server is offline. An explicitly rejected or expired token is removed and
  returns the user to sign-in.
- Unreachable servers and bad credentials have automated state coverage but
  have not been exercised on a physical device.
- Denied local-network permission, network loss during playback, expired tokens
  during browsing, empty libraries, and unsupported tracks still need real
  device/server smoke tests.
- Cached metadata and artwork are purgeable browsing accelerators, not offline
  playback. Audio remains transiently buffered by AVFoundation.
- The active queue keeps a bounded restoration window and expands Songs/Search
  while the originating view model is alive. Relaunch restores the saved window,
  not an unbounded server-side queue.
- Sample-accurate gapless playback is not promised for transcoded Jellyfin
  streams.
