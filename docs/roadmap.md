# Velacanto roadmap

This roadmap orders the work needed to reach the first functional prototype.
The detailed feature boundary and acceptance criteria remain in the
[0.1.0 plan](0.1-plan.md).

## Current focus

### Slice 0 — Project foundation

- [x] Establish the public repository and Git workflow.
- [x] Document the 0.1.0 scope and architecture.
- [x] Add a repeatable pre-build readiness check.
- [x] Select and initialize the required Xcode beta toolchain.
- [x] Finish installing the required iOS Simulator runtime.
- [x] Confirm minimum supported iOS and macOS versions.
- [x] Decide whether macOS is release-ready or compile-tested in 0.1.0.
- [x] Generate the SwiftUI app and unit-test targets.
- [x] Create a valid Xcode-managed Personal Team signing identity.
- [x] Enable Developer Mode, register the connected iPhone, and generate its
  temporary development provisioning profile.
- [x] Produce and install a signed physical-device build.
- [x] Trust the Personal Team developer profile on the iPhone and complete the
  first launch.
- [x] Add local-network purpose text and the narrow ATS policy.
- [x] Add and validate the privacy manifest.
- [x] Add a shared playback coordinator and direct local-file source adapter.
- [x] Produce clean macOS and generic simulator builds with passing foundation
  tests.
- [ ] Run the app and tests on a booted iOS Simulator.

The macOS build, nine foundation tests, and generic iOS Simulator build pass.
Local playback, observed engine state, resource lifetime, and system-media
behavior are covered at the coordinator boundary. The iOS 27 Simulator runtime
is installed; a booted simulator run remains pending.

Xcode account sign-in is complete and the July 29 preflight recognizes one
valid Personal Team development identity. The connected iPhone is registered,
provisioned, and running a signed Velacanto build. A 60-second local diagnostic
track continued after returning to the Home Screen, appeared with correct
metadata and timing in Control Center, and responded to Control Center pause
and resume. The team identifier remains a local build setting rather than a
value committed to the project. Paid Apple Developer Program enrollment is
deferred to 1.0.

**Exit gate:** A clean checkout builds and tests on the selected iOS and macOS
destinations without secrets or machine-local configuration in Git.

## 0.1.0 delivery

### Slice 1 — Connect and authenticate

- [ ] Normalize and validate a user-entered server URL.
- [ ] Query public Jellyfin server information.
- [ ] Authenticate a username and password.
- [ ] Store the access token in Keychain.
- [ ] Persist a stable app-generated Jellyfin device identifier.
- [ ] Restore a valid session at launch.
- [ ] Log out and delete the stored token.
- [ ] Cover invalid URL, unreachable server, bad credentials, and expired token.

**Exit gate:** A user can connect, authenticate, relaunch into the session, and
log out without Velacanto persisting the password.

### Slice 2 — Browse music

- [ ] Locate the signed-in user's music libraries.
- [ ] Load albums and artwork for the selected music library.
- [ ] Open an album and show tracks in server order.
- [ ] Represent loading, empty, retryable, and terminal error states.
- [ ] Add decoding and view-model state tests.

**Exit gate:** A signed-in user can navigate from their music library to a
specific playable track.

### Slice 3 — Stream and control playback

- [x] Play a user-selected local audio file in place without copying it.
- [x] Share play, pause, seek, elapsed-time, and duration behavior across source
  adapters.
- [ ] Resolve and begin the selected audio stream.
- [x] Configure the iOS playback audio session.
- [x] Enable the iOS background-audio mode and keep playback at app scope.
- [ ] Handle interruptions, route changes, and failed streams.
- [x] Publish now-playing metadata.
- [x] Handle system play, pause, stop, toggle, and seek commands.
- [x] Verify background playback, device lock, metadata, pause, and resume in
  Control Center on a physical iPhone.
- [ ] Repeat the smoke test on a booted iOS Simulator.

**Exit gate:** The selected track keeps playing under screen lock and responds
to the expected system media controls.

### Slice 4 — Stabilize 0.1.0

- [ ] Exercise the complete flow against a non-production Jellyfin server.
- [ ] Test denied local-network access and network loss.
- [ ] Test empty libraries, expired sessions, and unsupported tracks.
- [ ] Run clean iOS and macOS builds and all unit tests.
- [ ] Audit logs and tracked files for credentials and tokens.
- [ ] Document known issues.

**Exit gate:** The complete connect → browse → play journey satisfies the
[0.1.0 acceptance criteria](0.1-plan.md#acceptance-criteria).

## Later, not scheduled

These items remain intentionally outside 0.1.0:

- CarPlay interface and entitlement work.
- Offline downloads.
- Search and favorites.
- Playlist and queue editing.
- Lyrics.
- Casting and explicit transcoding controls.
- Multiple saved servers or users.
- Navidrome/Subsonic server connectivity. Its source adapter boundary is
  reserved, but Jellyfin remains the first server implementation.
- Analytics, paid Apple Developer Program enrollment, TestFlight, and App Store
  release automation. Public distribution will be reconsidered for 1.0.

## Decisions still required

- Non-production Jellyfin test-server ownership.
- Public source license and contribution policy.

Record durable technical choices in
[architecture decision records](decisions/README.md), not only in issues or
chat.
