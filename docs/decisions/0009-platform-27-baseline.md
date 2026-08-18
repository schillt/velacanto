# 0009 — Platform version 27 baseline

- Status: Accepted
- Date: 2026-08-17
- Supersedes: [0007](0007-platform-26-baseline.md)

## Context

The 0.3 review found that maintaining shared presentation across older
deployment targets was adding availability branches while the milestone still
needed platform-specific toolbar, queue, and system-media boundaries. The
project owner chose an OS 27 minimum so the release can use one current native
contract and remove compatibility paths rather than add another fallback layer.

The OS 27 Now Playing and reorderable-container APIs directly replace manual
system-media publication and older queue-edit presentation. The project remains
a sideloaded 0.x build, so this minimum is not a public compatibility promise.

## Decision

- Require iOS 27, iPadOS 27, and macOS 27 for Velacanto 0.3.
- Require Xcode 27 and Swift 6.4.
- Do not promote a final 0.3 candidate before the stable OS 27 SDK.
- Use OS 27 native reordering and Now Playing APIs when they replace custom code.
- Remove older availability branches after the project deployment targets move.
- Keep shared domain, provider, lyrics, queue, and playback state independent
  from UIKit and AppKit.
- Keep iOS/iPadOS and macOS presentation differences in small native chrome and
  framework adapters.
- Adapt iPad behavior through window size and environment rather than device
  identity.

## Consequences

- Devices on OS 26 or earlier cannot run 0.3.
- The preview checkpoint moves when the stable SDK or acceptance gates are not
  ready.
- Queue and system-media code can use one native OS 27 path without fallbacks.
- iPhone, iPad, and Mac still require separate rendered acceptance.
- The decision changes the product baseline; deployment-setting implementation
  and validation remain tracked by issue #78.
