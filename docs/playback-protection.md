# Playback and Now Playing protection

Owner-established contract, 2026-10-14. Apply this document to future changes in
playback, Now Playing, catalog loading, artwork, caching and their shared owners.
Root and NativeFoundation AGENTS.md make these requirements part of agent work.

## Acceptance checkpoint

Alpha182 contains runtime change `46aefa9`, based on Alpha181 `0ae4c77`.
Device source `b38b8bd` changes only the build number to182; `4bb0281` records
installation. The owner subsequently reported: “This build seems to pass initial
testing.” Record this as **owner-reported initial acceptance of build182**.
The report does not specify a device-by-device test matrix or establish the cause
of the earlier failure. It is not exhaustive playback, route or release acceptance.

Before this change, the owner reported no audio, a continuous loading spinner and
incomplete expanded Now Playing artwork after recent loading changes. Code review
found shared artwork scheduling/recovery weaknesses, but no direct artwork-to-audio
wait. Audio URL resolution and AVPlayer delivery were already independent. Shared
server/device resource contention remained a hypothesis. Recovery after an update
or network reset is not proof of a specific cause, corrupted cache or OS defect.

## Protected behavior

1. **Only playback and Now Playing receive special loading priority.** Artist,
   Album, Home, New, Library, Search, playlists and related content are one equal
   browsing class. Opening a page or submitting a search does not promote it.
2. **Audio never waits for optional content.** Do not put native audio delivery,
   session activation, play/pause/skip/seek or stream URL resolution behind artwork,
   metadata, disk persistence, page completion or optional request permits.
   Sequential collection expansion needed to fulfill an explicit Play action is
   playback work. Ordinary queue additions remain browsing work.
3. **Protection changes admission, not presentation.** Cached results bypass
   network admission. Completed sections appear independently. Preserve bounded
   parallel browsing and the faster Artist experience; do not restore whole-page
   completion barriers or invent a priority hierarchy among browsing screens.
4. **Use existing playback ownership.** Derive protection from playback intent,
   loading/waiting and pending audio-session startup. Reject stale asynchronous
   state updates. Pause, failure, completion and account retirement must release
   the relevant protection or demand. No second player or independent playback
   state machine is justified by this policy.
5. **Protect Now Playing throughout the request path.** Reserve bounded worker
   and pending-request capacity. A protected consumer joining an existing request
   must promote that request, including a worker already awaiting network admission.
   Preserve intent through detached work. Do not duplicate a fetch to gain priority.
6. **Artwork remains optional and recoverable.** Keep a usable current image sharp
   while upgrading. Do not downgrade the same identity to a smaller image. Reset
   identity before comparing resolutions so a previous album cannot suppress a new
   image. A missing initial image must not prevent expanded artwork from loading.
   Retry only at defined user/recovery boundaries, with scoped failure-cache
   invalidation; never add redraw-driven requests or automatic retry loops.
7. **Cancellation and lifetime are part of correctness.** Release permits on all
   outcomes; cancel queued waiters safely; remove promotion records when ownership
   ends; reject late account results. One consumer leaving must not cancel shared
   work still needed by another. Keep finite resource budgets explicit.

## Current implementation and limits

| Boundary | Alpha182 behavior |
| --- | --- |
| Catalog/artwork GET admission | Account-owned `FoundationNetworkAdmission`; six active reads maximum, ordinary reads limited to five, preserving a protected slot. |
| Playback starting or waiting | New ordinary admission limited to one while playback is requested; pending audio-session startup is included. Ordinary progress remains possible. |
| Artwork workers and pending keys | Four workers, at most three ordinary workers; one of the128 pending-key positions reserved for protected demand. Shared requests can be promoted. |
| Current artwork recovery | Missing current artwork may retry on Now Playing open or successful explicit connectivity retry; failures are cleared for that image identity. |
| Existing transport | AVPlayer remains independent. Authentication, mutations and original-file download transport retain their existing policies. |

These are implementation settings, not guaranteed network bandwidth or measured
performance claims. In-flight reads finish normally; the gate does not preempt
server work, downloads or OS networking. Artwork workers still retain capacity
through persistence. Expanded high-resolution ownership remains view-local over
the shared cache. Seek protection follows native loading/waiting rather than a
separate immediate seek lifetime. Changes to limits need a concrete rationale,
boundedness tests and relevant performance/playback evidence.

## Required review and verification

Treat shared loader, cache, rendition, task-lifetime, animation-publication and
concurrency changes as potentially playback-relevant even when their visible
feature is an Artist page or another browsing screen. “Player code unchanged” is
not evidence of playback isolation under load.

Before changing these paths, identify affected consumers and existing ownership,
then state how protected work, cancellation and cached publication remain intact.
Use existing seams; do not add speculative transport replacement, watchdogs,
automatic retries, cache purges or global serialization to mask an unresolved stall.

Run the affected existing regression suites and add focused tests for changed
contracts. Required cases for admission/recovery changes include:

- Hold ordinary reads; prove protected catalog/artwork work can progress and audio
  URL resolution does not enter that queue. Test the actual adapter, not just a
  standalone scheduler.
- Fill worker and pending-key budgets separately. Promote an already-shared request
  while it waits; verify one fetch, finite capacity and cleanup after cancellation.
- Exercise stale protection updates, pending audio-session activation, pause,
  failure, cancellation and account retirement without stranded waiters.
- Exercise explicit collection Play through pagination, preserving protected
  intent; verify ordinary queue additions and browsing remain unprivileged.
- Fail initial artwork, recover at the defined boundary, retain usable images
  during upgrades and change to a new artwork identity without stale publication.
- Keep fast or cached page sections visible while another section is delayed.

Use relevant Mac/iOS tests, platform builds and Release diagnostic-exclusion checks.
Supply the candidate's actual `VELACANTO_BUILD_NUMBER` to the release verifier;
do not weaken it to accommodate an outdated default. Documentation-only changes
need link/consistency/whitespace review, not new Xcode runs.

For changes affecting shared runtime loading, acceptance also requires the exact
installed candidate's physical playback check: stream while browsing/loading,
expand Now Playing, change tracks and seek. Check background, queue advancement
and routes when affected. Record platform, build, action order and owner-confirmed
audible outcome; do not infer audibility from a progressing timer or screenshot.
Preserve sign-in, saved queue/cache and prior artifacts during update checks.
Do not use excluded devices or publish/install unrelated candidates implicitly.

A report of silent playback with persistent loading is a P1 acceptance blocker.
Capture bounded DEBUG evidence distinguishing resource resolution, previous-session
waiting, activation and native waiting/failure. Preserve the failing candidate and
reproduction; fix the demonstrated path and repeat affected gates. Initial owner
acceptance can establish a new checkpoint without proving the original root cause.
Unverified gates remain explicit and do not imply release/publication authorization.

## Lessons from this change

- Independent publication and unrestricted starts are different choices. Artist
  responsiveness can coexist with protection for the app's primary function.
- Swift task priority alone is not a network admission policy. A shared cache can
  lose protected intent through detached work or an earlier browsing owner.
- Reserving workers alone is insufficient: ordinary pending demand can still
  reject protected work. Cancellation must also clean promotion metadata.
- A ready/paused native item does not necessarily mean session activation finished.
  Protect the existing pending-start lifetime as well as loading/waiting states.
- A visual upgrade must preserve useful content and retain a recovery path. A
  low-resolution publication must not erase a sharper result for the same identity.
- Passing unit tests and loaded Artist screenshots did not establish audio safety.
  Alpha182 added ten tests plus a held-activation assertion:508 Mac tests and257
  affected iOS tests passed; signed device builds and initial owner acceptance
  provide additional, separately scoped evidence.

See [development evidence](0.4-development-record.md#playback-and-now-playing-protection--local-refinement-2026-10-14)
and the [ADR0012 scoped amendment](decisions/0012-foundation-rebuild-and-playback-freeze.md#scoped-amendment--playback-and-now-playing-protection-2026-10-14).
