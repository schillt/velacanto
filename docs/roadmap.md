# Velacanto roadmap

This roadmap orders the work needed to stabilize the first functional app.
The detailed feature boundary and acceptance criteria remain in the
[0.1.0 plan](0.1-plan.md).

## Current focus

Slices 0 and 1 are complete. The native Home, Library, Search, profile, and
playback surfaces are implemented across iOS and macOS, including authenticated
Jellyfin artwork. The full Slice 1 happy path has been verified against a real
Jellyfin server on a physical iPhone. Current work is complete browse-and-play
real-server validation, live failure testing, accessibility validation, and
playback lifecycle reporting.

## Foundation status

### Slice 0 — Project foundation

**Status: Complete.**

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
- [x] Run the app and tests on a booted iOS Simulator.

The macOS build, twenty-eight foundation and Jellyfin tests, and generic iOS
Simulator build pass. Local playback, observed engine state, resource lifetime,
system-media behavior, Jellyfin URL policy, request construction, decoding,
Private token-file migration, session persistence, artwork requests, catalog
aggregation, and stream handoff are covered. The app launches and the foundation
tests have passed on macOS and a booted iOS 27 Simulator.

The physical-device path was verified with a Personal Team identity on July 29.
The connected iPhone was registered, provisioned, and ran a signed Velacanto
build. A 60-second local diagnostic track continued after returning to the Home
Screen, appeared with correct metadata and timing in Control Center, and
responded to Control Center pause and resume. Signing identities and profiles
remain machine-local and may need to be renewed; the team identifier is not
committed to the project. Paid Apple Developer Program enrollment is deferred
to 1.0.

**Exit gate:** A clean checkout builds and tests on the selected iOS and macOS
destinations without secrets or machine-local configuration in Git.

## 0.1.0 delivery

### Slice 1 — Connect and authenticate

**Status: Complete.**

- [x] Normalize and validate a user-entered server URL.
- [x] Query public Jellyfin server information.
- [x] Authenticate a username and password.
- [x] Store the access token in private app storage without Keychain prompts.
- [x] Persist a stable app-generated Jellyfin device identifier.
- [x] Restore a valid session at launch.
- [x] Log out and delete the stored token.
- [x] Cover invalid URL, unreachable server, bad credentials, and expired token
  behavior with automated tests.

On July 29, 2026, the connect → authenticate → relaunch → restore → logout
journey was verified against a real Jellyfin server on a physical iPhone.
Unreachable-server and bad-credential behavior has automated coverage but still
needs physical-device testing under Slice 4.

**Exit gate:** A user can connect, authenticate, relaunch into the session, and
log out without Velacanto persisting the password.

### Slice 2 — Browse music

- [x] Locate the signed-in user's music libraries.
- [x] Load albums for the selected music library.
- [x] Load album artwork.
- [x] Open an album and show tracks in server order.
- [x] Represent loading, empty, retryable, and terminal error states.
- [x] Add decoding and view-model state tests.

**Exit gate:** A signed-in user can navigate from their music library to a
specific playable track.

### Slice 3 — Stream and control playback

- [x] Play a user-selected local audio file in place without copying it.
- [x] Establish source-neutral play, pause, seek, elapsed-time, and duration
  behavior for local and future server adapters.
- [x] Resolve and begin the selected Jellyfin audio stream.
- [x] Configure the iOS playback audio session.
- [x] Enable the iOS background-audio mode and keep playback at app scope.
- [x] Observe readiness, waiting, play, pause, completion, stalls, and player
  failures through the injectable playback engine.
- [x] Handle audio-session interruptions and route changes.
- [x] Validate recovery behavior for failed Jellyfin streams.
- [x] Publish now-playing metadata.
- [x] Handle system play, pause, stop, toggle, and seek commands.
- [x] Verify background playback, device lock, metadata, pause, and resume in
  Control Center on a physical iPhone.
- [x] Repeat the smoke test on a booted iOS Simulator.

**Exit gate:** The selected track keeps playing under screen lock and responds
to the expected system media controls.

### Slice 4 — Stabilize 0.1.0

- [ ] Exercise the complete flow against a non-production Jellyfin server.
- [ ] Test an unreachable server and bad credentials on a physical device.
- [ ] Test denied local-network access and network loss.
- [ ] Test empty libraries, expired sessions, and unsupported tracks.
- [x] Run clean iOS and macOS builds and all unit tests.
- [x] Audit logs and tracked files for credentials and tokens.
- [x] Document known issues.

**Exit gate:** The complete connect → browse → play journey satisfies the
[0.1.0 acceptance criteria](0.1-plan.md#acceptance-criteria).

## Later, not scheduled

These items remain intentionally outside 0.1.0:

- CarPlay interface and entitlement work.
- Offline downloads.
- Favorites.
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
