# Velacanto known issues

This list records current operational limitations. It is not a substitute for
the [0.3 acceptance matrix](0.3-stability-acceptance.md).

- The current checked-in project still targets iOS 18 and macOS 15. ADR 0007
  raises the 0.3 product baseline to iOS/iPadOS 26 and macOS 26; implementation
  work must update and validate the project settings.
- General library presentation currently consumes `JellyfinItem`. Issue work
  for 0.3 introduces a provider-neutral catalog/action boundary before the UI
  and future CarPlay surface expand.
- Universal audio streaming requests MP3 as the fallback transcode format.
  Direct-play and transcode behavior still need broader Jellyfin version and
  codec coverage.
- AVPlayer receives a playback URL containing the Jellyfin access token as an
  API query parameter. Velacanto does not log it, but errors and diagnostics
  must continue treating playback URLs as sensitive.
- A saved session remains available when launch validation fails because the
  server is offline. An explicitly rejected token is removed.
- Seven audio-session, route-recovery, and system-command tests fail only in the
  iOS Simulator runtime suite; corresponding physical-device scenarios passed.
- Metadata and artwork caches are account-isolated browsing accelerators, not
  offline playback. The artwork cache is bounded to 64 MB; user-visible storage
  management and offline policy remain 0.4 work.
- The active queue restores a bounded window. Editable Up Next, shuffle, and
  repeat are 0.3 work and must retain that bounded restoration policy.
- Sample-accurate gapless playback is not promised for transcoded streams.
