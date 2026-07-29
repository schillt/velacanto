# 0001 — Shared core with native platform surfaces

- Status: Accepted
- Date: 2026-07-29

## Context

Velacanto initially targets iOS and macOS, with CarPlay planned after the core
playback experience. Authentication, Jellyfin requests, library models, session
state, and most playback policy should behave consistently across platforms.
Navigation, lifecycle, windowing, and some media behavior differ by platform.

The 0.1.0 prototype also needs to remain easy to test and should avoid
third-party dependencies that do not remove meaningful risk.

## Decision

- Build the user interfaces with SwiftUI.
- Share domain models, the Jellyfin API client, session behavior, library
  behavior, and playback policy where platform APIs permit.
- Keep platform-specific presentation and adapters separate when iOS and macOS
  behavior differs.
- Use Apple frameworks for networking, secure storage, playback, audio session,
  now-playing metadata, and remote commands.
- Inject networking, credential storage, and playback boundaries so tests do not
  require a live server or active audio session.
- Isolate mutable API and session state with Swift concurrency.
- Treat CarPlay as another presentation surface over the proven shared core, not
  as a separate playback implementation.

## Consequences

- Core behavior can be tested once and reused across iOS and macOS.
- Platform interfaces may intentionally diverge instead of accumulating
  conditional UI code.
- Apple-framework behavior remains visible and debuggable without an additional
  abstraction dependency.
- The project must maintain clear protocols at service boundaries.
- CarPlay work depends on both a stable playback coordinator and Apple's managed
  entitlement.
