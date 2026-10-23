# 0010 — Internal TestFlight for approved 0.x candidates

- Status: Accepted
- Date: 2026-08-26
- Supersedes: [0005](0005-sideload-only-for-0-x.md)

## Context

Physical installation remains essential for validating playback, network, and
session behavior. The 0.2.5 stabilization candidate has completed a bounded
physical-device matrix and now needs a reproducible internal distribution path
without representing the product as ready for public App Store release.

## Decision

- Approved 0.x stabilization candidates may be distributed through internal
  TestFlight after exact-source local and hosted gates pass.
- Internal TestFlight does not authorize external testing, App Review
  submission, automatic public release, or a live App Store release.
- The repository records the exact source commit, marketing version, build
  number, verification, and accepted limitations for each uploaded candidate.
- Signing credentials, provisioning material, tester identities, and private
  server or media data remain outside the repository.
- Public distribution policy and App Store launch readiness remain 1.0 work.

## Consequences

- Internal testers can exercise one signed, provenance-matched build without
  relying on temporary local installs.
- Release coordination must keep TestFlight acceptance separate from public
  App Store submission and must stop for owner decisions involving agreements,
  compliance, tester access, review, or public release.
- A failed or superseded internal build does not change the public-release
  roadmap and must retain an explicit disposition in the release record.

## Owner clarification — 2026-10-23

Automatic TestFlight delivery is main-only. Owner-started manual Cloud/TestFlight
pushes remain separate release actions; existing manual-workflow post-actions
must not be removed merely because the selected source is alpha. Do not promote
branches as a delivery workaround or broaden testers/public-release scope.

For the 0.5.0 preview, the owner is handling the manual TestFlight push while
GitHub cleanup and the failed artwork-fixture checks are investigated separately.
This is a recorded owner-directed distribution path, not a passing quality result
or a general waiver of the release gates above. Apple processing and tester
availability still require actual evidence.
