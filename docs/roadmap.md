# Velacanto roadmap

This roadmap orders the work needed to reach the first functional prototype.
The detailed feature boundary and acceptance criteria remain in the
[0.1.0 plan](0.1-plan.md).

## Current focus

### Slice 0 — Project foundation

- [x] Establish the public repository and Git workflow.
- [x] Document the 0.1.0 scope and architecture.
- [x] Add a repeatable pre-build readiness check.
- [ ] Select and initialize the required Xcode beta toolchain.
- [ ] Confirm minimum supported iOS and macOS versions.
- [ ] Decide whether macOS is release-ready or compile-tested in 0.1.0.
- [ ] Generate the SwiftUI app and unit-test targets.
- [ ] Configure `com.chameleonenterprise.velacanto` and Apple signing.
- [ ] Add local-network purpose text and the narrow ATS policy.
- [ ] Add and validate the privacy manifest.
- [ ] Produce clean simulator builds and passing foundation tests.

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

- [ ] Resolve and begin the selected audio stream.
- [ ] Implement play, pause, seek, elapsed time, and duration.
- [ ] Configure the playback audio session.
- [ ] Enable and test iOS background audio.
- [ ] Handle interruptions, route changes, and failed streams.
- [ ] Publish now-playing metadata.
- [ ] Handle system play and pause commands.

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
- Analytics and App Store release automation.

## Decisions still required

- Minimum iOS and macOS deployment targets.
- The macOS release commitment for 0.1.0.
- Local plain-HTTP server support policy.
- Apple Developer team and bundle-ID registration.
- Non-production Jellyfin test-server ownership.
- Public source license and contribution policy.

Record durable technical choices in
[architecture decision records](decisions/README.md), not only in issues or
chat.
