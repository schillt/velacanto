# Velacanto known issues

This list describes the current pre-alpha limitations after the first Jellyfin
vertical slice. It is not a release-readiness statement.

- The Slice 1 connect, authenticate, relaunch, restore, and logout journey has
  been verified against a real Jellyfin server on a physical iPhone. The
  complete connect → browse → play journey still needs end-to-end validation on
  iOS and macOS.
- Album and track queries use generous fixed limits rather than pagination.
- Artwork uses authenticated Jellyfin image URLs and the system image loader;
  explicit cache policy and offline artwork are not implemented.
- Jellyfin playback start, progress, and stop events are not reported to the
  server yet, so server-side recent-play and resume state may not update.
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
