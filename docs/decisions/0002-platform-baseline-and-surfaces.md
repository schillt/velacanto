# 0002 — Platform baseline and 0.1.0 surfaces

- Status: Accepted
- Date: 2026-07-29

## Context

Velacanto needs explicit deployment targets that are independent of the beta
macOS and Xcode versions used by the development machine. The 0.1.0 plan also
needs a clear macOS commitment so platform support is testable rather than
aspirational.

The initial project builds successfully with the iOS 27 and macOS 27 SDKs while
targeting earlier production operating systems.

## Decision

- Set the minimum deployment target to iOS 18.0.
- Set the minimum deployment target to macOS 15.0.
- Deliver native iOS and macOS application surfaces in 0.1.0.
- Require the core connect, authenticate, browse, and playback journey to work
  on both platforms.
- Treat the selected Xcode beta as a build-host requirement, not as the minimum
  operating-system version for users.

## Consequences

- Velacanto can use a modern SwiftUI and Swift concurrency baseline without
  requiring users to run the same beta operating systems as developers.
- Shared core behavior still needs platform-specific build and runtime
  verification.
- Features introduced after iOS 18 or macOS 15 require availability checks or a
  future deployment-target decision.
- The minimum versions can be raised before public release if real-device
  testing reveals beta-toolchain incompatibilities.
