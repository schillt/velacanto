# 0007 — Platform version 26 baseline

- Status: Superseded by [0009](0009-platform-27-baseline.md)
- Date: 2026-08-11
- Supersedes: [0002](0002-platform-baseline-and-surfaces.md)

## Context

Velacanto 0.1 and 0.2 targeted iOS 18 and macOS 15 while adopting newer
SwiftUI behavior through availability branches. Version 0.3 is explicitly a
native-player interface release across iPhone, iPad, and Mac. Maintaining two
navigation and playback-presentation paths would expand the implementation and
test matrix during the release whose purpose is to make those surfaces coherent.

The app remains a sideloaded 0.x project, so the compatibility range is not yet
a public distribution promise.

## Decision

- Require iOS and iPadOS 26 or newer for 0.3 development.
- Require macOS 26 or newer for 0.3 development.
- Build and test against current supported Xcode 26 and 27 toolchains/runtimes
  where available.
- Use current native SwiftUI tab, sidebar, search, toolbar, inspector, material,
  and playback-accessory behavior directly.
- Remove compatibility branches that exist only for iOS 18–25 or macOS 15–25
  when the 0.3 implementation updates project deployment settings.
- Treat a future minimum-version change as a new product decision.

## Consequences

- The 0.3 UI can have one native behavioral contract instead of parallel shells.
- iOS 18–25 and macOS 15–25 devices cannot run 0.3 builds.
- iPhone, iPad, and Mac still require distinct adaptive acceptance; a common
  minimum OS does not justify a shared view hierarchy where platforms differ.
- The planning package records the decision but does not change project settings
  before feature implementation begins.
