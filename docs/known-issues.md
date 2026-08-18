# Velacanto known issues

This list records current operational limitations. It is not a substitute for
the [0.3 acceptance matrix](0.3-stability-acceptance.md).

- Every checked-in app and test target now requires iOS/iPadOS 27 or macOS 27,
  Xcode 27, and Swift 6.4. Preview and final promotion remain blocked until the
  stable OS 27 SDK is available and the full acceptance matrix passes.
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
