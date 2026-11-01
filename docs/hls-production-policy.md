# HLS streaming policy — build195 candidate

> Historical development record. Candidate-stage status below describes that
> checkpoint, not current availability. The 0.5.0 integration includes the accepted
> HLS, quality/download and modern Mac credential work; see the authoritative
> [0.5.0 acceptance and release record](0.5.0-acceptance.md) for current scope,
> superseding evidence and pending publication/TestFlight gates. Earlier DEBUG-only
> restrictions and “not installed” statements must not be read as current policy.

Owner authorization, 2026-10-22: make HLS the only in-app remote delivery policy,
remove delivery choices and validate the production path. This supersedes the
DEBUG-only comparison limit recorded in the build194 handoff. It does not
authorize publication, TestFlight upload or a claim of complete route acceptance.

## Source and preserved behavior

The isolated local branch `codex/hls-production-policy` starts at
`58080ccf9da83f7311e519d2888721bda0d07810`, the accepted build194 checkpoint.
The previous worktree, apps and evidence remain preserved. Fetching remote alpha
failed because GitHub's hostname could not resolve; remote integration is pending.
This is deliberate continuation of the supplied local dependency chain, not a
claim that those dependencies are published on alpha.

Preserve build188 actual-history/new-continuation behavior, build193 one-shot
Siri audio-session continuation and build194 native CarPlay Back control.
The owner reports CarPlay looks good so far; broader real-vehicle coverage is
deferred to release testing, not represented as completed.

The base contains the playback-protection owners and production seams described
in [the contract](playback-protection.md): only playback/Now Playing is privileged,
browsing publishes independently and optional content never gates audio. This
change retains those owners; it does not introduce another player or retry loop.

## Delivery

All live remote playback calls the existing resource-owning HLS preparation path
in Debug and Release. Compatible MP3 requests copy over MPEG-TS HLS; eligible AAC,
FLAC and ALAC request copy over MP4 HLS. Other recognized source formats request
AAC with a 320 kbps limit. Existing source identity, stream/codec metadata,
source-drift, rendition and same-origin URL validation remain authoritative.
Unknown/unsupported source descriptions or denied HLS fail explicitly. There is
no automatic fallback to the former direct-preferred policy.

Original-file downloads still play locally. The delivery comparison picker and
its persisted preference reader are removed. Old values can remain in storage
but cannot select a delivery mode. Settings shows the fixed HLS policy. A DEBUG
TaskLocal fixture seam can exercise AAC preparation without metadata selection;
it is not a user setting or a Release override.

The URL-only protocol compatibility helper remains for existing adapters/tests;
the live account/player/download resource route does not use it for remote media.
Do not derive a URL by discarding an HLS resource: its exact-session lease must
remain owned by the player and be released on existing replacement/cancellation
boundaries.

Metadata and copy-master preflight retain the explicit playback transport,
bypassing optional GET admission. Review caught that the old Release branch of
`responseData` ignored that override. Release now honors it too. Exact-session
cleanup therefore also retains the existing bounded eight-second transport.
Cleanup remains one active operation, 32 pending, ten-second pending age, and no
retry; release returns without waiting for the network operation.

Detailed HLS diagnostics and fixture injection remain DEBUG-only. Production
URL/query authentication is unchanged; [issue #25](playback-url-privacy.md)
remains open. HLS does not eliminate token-bearing media URLs or establish safe
server/proxy logging.

## Validation and remaining acceptance

The non-DEBUG production regression covers four historical preference values,
each with copied MP3 and Opus-to-AAC negotiation. It holds ordinary admission,
requires preparation to progress before releasing that permit, verifies direct
flags are disabled and checks no universal-audio request is made. Existing
format, URL, copy rendition, cancellation, source-drift and lease tests remain.
Cleanup bound/coalescing/expiry/exact-once tests now compile in Release too.

The focused Release harness compiles the self-contained reporting/HLS test file
with testability enabled and selects only `FoundationHLSProductionTests` and
`FoundationHLSCleanupTests`. Unrelated DEBUG-fixture test files are excluded for
that command only. Original listening-report tests use DEBUG-only test tones and
are gated accordingly; all their assertions remain in the full Debug suites.
This is focused Release validation, not a claim that the entire legacy test
suite runs in Release. Final shipping builds do not use those harness overrides.

Record exact build/test/install outcomes in the development record. Passing
synthetic negotiation does not prove actual server encoding, audibility or every
codec/container/route. Exact-candidate physical checks remain: start, forward/back
skip, seek, natural advance, Play Next then Next, expanded Now Playing, background
and affected AirPlay/CarPlay routes. Preserve sign-in and device network settings;
do not erase caches or reset networking to obtain a pass.
