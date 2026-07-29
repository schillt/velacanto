# 0005 — Sideload-only deployment for 0.x

- Status: Accepted
- Date: 2026-07-29

## Context

Velacanto needs frequent simulator and physical-device testing while the core
playback and server integrations are still changing. App Store submission,
TestFlight operations, and paid Apple Developer Program enrollment would add
distribution work before the product is ready for a public 1.0 release.

An iOS app cannot be installed on a physical device without a valid code
signature. A free Apple Account can provide an Xcode-managed Personal Team for
development installs, but its provisioning is temporary and more limited than
paid program membership.

## Decision

- Keep every 0.x release local-development or sideload only.
- Do not publish 0.x builds through the App Store or TestFlight.
- Continue using unsigned macOS and simulator builds for repeatable automated
  checks.
- Use Xcode-managed Personal Team signing for physical iPhone and iPad testing
  where its limits are acceptable.
- Do not commit certificates, provisioning profiles, account identifiers, or
  other machine-local signing material.
- Pursue paid Apple Developer Program enrollment, public distribution, and the
  App Store release process at the 1.0 milestone.

## Consequences

- 0.x can focus on the product and direct device validation without claiming a
  public distribution channel.
- Physical-device testers may need to rebuild or reinstall when temporary
  provisioning expires.
- The repository can remain public even though compiled 0.x distribution is
  intentionally limited.
- Each physical-device tester must validate signing and bundle-ID provisioning
  locally; only paid membership and public distribution are deferred.
- The 1.0 plan must include distribution certificates, long-lived provisioning,
  App Store Connect setup, privacy disclosures, release automation, and review
  readiness.
