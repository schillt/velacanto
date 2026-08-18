# Velacanto known issues

This list records current operational limitations. It is not a substitute for
the [0.3 acceptance matrix](0.3-stability-acceptance.md).

- The current checked-in project still targets iOS 18 and macOS 15. ADR 0009
  raises the 0.3 product baseline to iOS/iPadOS 27 and macOS 27; issue #78 must
  update and validate every app and test target.
- Local `alpha` history and three dirty worktrees were preserved on August 17,
  2026. Issue #76 and PR #77 own normalization; recovery state must remain until
  every patch hunk has an issue disposition.
- Universal audio streaming requests MP3 as the fallback transcode format.
  Direct-play and transcode behavior still need broader Jellyfin version and
  codec coverage.
- AVPlayer receives a playback URL containing the Jellyfin access token as an
  API query parameter. Velacanto does not log it, but errors and diagnostics
  must continue treating playback URLs as sensitive.
- A saved session remains available when launch validation fails because the
  server is offline. An explicitly rejected token is removed.
- Committed unit suites pass, but the restored UI-test target currently runs two
  iOS tab-bar tests against macOS, where both navigation assertions fail. Issue
  #61 owns platform-appropriate UI automation and signed-in coverage.
- Metadata and artwork caches are account-isolated browsing accelerators, not
  offline playback. The artwork cache is bounded to 64 MB; user-visible storage
  management and offline policy remain 0.4 work.
- The active queue restores a bounded window. OS 27 reordering and final
  interruption/session acceptance remain in issue #12 and must retain that
  bounded restoration policy.
- Lyrics exist in recovered working changes but are not integrated. Issues #80
  and #81 own the provider-neutral data path and native presentation.
- Sample-accurate gapless playback is not promised for transcoded streams.
