# Download quality — isolated integration candidate

> Historical development record. Candidate-stage status below describes that
> checkpoint, not current availability. The 0.5.0 integration includes the accepted
> HLS, quality/download and modern Mac credential work; see the authoritative
> [0.5.0 acceptance and release record](0.5.0-acceptance.md) for current scope,
> superseding evidence and pending publication/TestFlight gates. Earlier DEBUG-only
> restrictions and “not installed” statements must not be read as current policy.

Owner-authorized development, 2026-10-22. Backend checkpoint base:
`8b6d946c9ea54b6e48f0c54d0a193a61d3b914d2`; reviewed backend commits
`7e1be284d8944913db1a0199cc0aa5b76094997b` and
`100a0c753c79fe86a80efd0752891909bb716a17` are reconciled onto accepted UI207
`5cf5d27a79a3643d361b073011fa49a76fdfa428` in this isolated integration.
No fixed/Auto streaming changes are included. This local candidate is not installed,
accepted or published and its version remains207 pending coordinated integration.
Remote integration remains unverified. Playback protection is retained through the
supplied reconciled local lineage; literal historical182 ancestry is not claimed.

## Implemented here

- Download-only Original/default and AAC320/192/128 policy values. These are
  independent of streaming policy. No Auto download policy is selected implicitly.
- Optional persisted ownership quality, absent meaning Original. The download
  manager preserves it on restore, retry and normal saves. Existing verified files
  remain reusable regardless of requested quality. New ownership snapshots the
  download preference once. Retries, restore and playlist reconciliation retain
  that intent. The iOS system Settings selector owns this preference; no Profile selector is shown.
  Invalid/missing preference values resolve to Original.
- A Jellyfin conversion proposal freshly reads current user policy and
  item metadata. Unknown/denied download or audio-transcoding permission, wrong
  account/item, ambiguous source, missing finite duration/index, remote/opening
  source or required source headers fail closed. This proposal starts no encoding.
- Exact progressive AAC/M4A request and separate exact-session cleanup request,
  header authentication, no token query. The conversion request contract rejects
  changed origin/path/source/session, bodies, missing or duplicate parameters,
  unknown keys and conflicting values. It explicitly disables stream copy/VBR and
  starts at zero with stereo48kHz output.
- A duration/target-bitrate ceiling plus15% overhead and1MiB mux allowance, checked
  against the caller's sampled available capacity. This is not an exact byte count
  or a disk reservation. Original byte-exact validation is unchanged.
- Output-facts checks require expected AAC/container/channel/rate, near-zero first
  packet, full expected duration, last packet end and successful EOF. These checks
  are exercised by the native file inspector described below.
- A separate converted-transfer executor applies that ceiling without
  asserting exact output length, preserves indeterminate progress, rejects
  redirects/unverified responses, and stages only regular nonsymlink files. Native
  inspection runs on a cancellable utility task: it checks ISO BMFF/AAC format,
  stereo48kHz audio, then walks every compressed sample through the current
  AVAssetReader output-provider API, verifies continuous timing, successful EOF
  and full expected duration. It does not create a player or decode PCM.
- A verified return contains digest, actual bytes and inspected rendition metadata.
  The file manifest has optional actual rendition metadata; absent remains an
  original/historical file. Existing size/hash validation and leases are unchanged.
- Every attempted transfer awaits one detached exact-session cleanup attempt after
  network completion/cancellation and before returning publishable bytes. Native
  cleanup rejects redirects and is bounded to8seconds and4KiB response budget.
  Cleanup failure removes staged output and returns an explicit failure. This does
  not prove the deployed server stopped every process or prevent late server work.

The existing sequential worker asks the provider-neutral library boundary for an
original or converted preparation. A converted owner cannot silently fall back to
Original. It invokes the separate verified executor and uses the existing atomic
file/manifest publication boundary, persisting the actual rendition. Account epoch,
owner existence, cancellation, connectivity and pause checks follow every manager
suspension. A projection/exclusion check after transfer also prevents publishing
tracks hidden during the transfer. Late progress from retired accounts is ignored.

Existing ready files are checked before proposal resolution and never replaced
because a quality preference changed. Playback file leases, original transport
validation and the player remain unchanged. Temporary conversion credentials,
requests and session identities are never persisted in the manifest or diagnostics.

## Remaining before enabling the feature in an installed build

1. Compile and run the backend's native AAC/truncation, response, byte-budget,
   cancellation, cleanup and rendition-persistence fixtures, plus manager tests for
   new-owner snapshots, ready-file reuse, retry intent, late retired results,
   cleanup failure and atomic rendition publication. None has been compiled/run
   in this integration: the coordinator has reserved the serialized build lane.
2. Independently review this exact candidate and reconcile accepted streaming
   integration without copying an older project version or settings snapshot.
3. Serial Mac/iOS tests, Release diagnostic exclusion and signed build checks.
4. Physical Original and each AAC preset acceptance, including offline playback,
   cancellation, retry and HLS playback during conversion. Server conversion can
   consume shared server CPU even with an independent client worker; no bandwidth,
   latency or playback-isolation guarantee is claimed.

Fresh client permission checks have a check-to-transfer revocation window. The
progressive endpoint does not atomically enforce Jellyfin's Download policy at
its own request boundary. This is distinct from bypassing a known denial: the
client must reject denied or unverifiable authorization. Do not describe this as
atomic server enforcement or as evidence that conversion is impossible.

## Source evidence and verification limits

Pinned SDK3.1.0, revision`50be9e583438be414a15d4bba933ff64b6769a91`, exposes
`getAudioStreamByContainer` with bitrate, codec, copy flags and play-session
parameters; `getDownload` has no conversion options.
[AudioController](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/AudioController.cs)
documents Static=true as the original-file path and maps progressive parameters.
[AudioHelper](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Helpers/AudioHelper.cs)
starts progressive conversion when Static=false.
[EncodingHelper](https://github.com/jellyfin/jellyfin/blob/master/MediaBrowser.Controller/MediaEncoding/EncodingHelper.cs)
constructs progressive audio encoding and MP4 movflags.
[StreamingHelpers](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Helpers/StreamingHelpers.cs)
uses the supplied source/session when preparing output.
[HlsSegmentController](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/HlsSegmentController.cs)
scopes encoding deletion by device and play-session identity. These are source
observations, not verification of the owner's deployed server version.

Added synthetic XCTest fixtures cover permission/account/item failures, complete
query mutation and duplicate rejection, byte ceilings, format/truncation facts,
legacy manifests, preserved retry intent and reuse of verified files. Follow-up
fixtures generate native AAC locally and exercise full packet inspection, truncation,
converted success/failure/cancellation, wrong-session cleanup, symlinks/oversize,
indeterminate progress and actual rendition persistence. **The tests
have not been compiled or run**: the coordinator reserved the Xcode/build lane.
Formatting lint, project-plist validation, whitespace checks and preflight without
Xcode passed. Preflight reported skipped Xcode checks and absent signing identity;
no signing, server, device or audible playback evidence is claimed.

### Initial compiler validation

The first authorized Debug Mac focused run stopped before test execution: two
backend fixtures omitted FoundationItem's required duration argument. Those
fixtures now supply their synthetic180-second/1-second durations. Production
source compilation reached the test target without a reported production error;
this is not a successful build/test result. Formatting and whitespace checks pass.
The serialized build lane was returned for the higher-priority installed streaming
candidate investigation before rerunning. Mac/iOS tests and Release gates remain
pending; no download candidate was installed.

The corrected Debug Mac candidate executed100 focused tests. Account2,
original-transport15, manager61 and offline6 tests passed. Quality-backend16
reported failures: its policy fixtures lacked the pinned SDK's required unrelated
AuthenticationProviderId/PasswordResetProviderId fields, preventing any permission
assertion from reaching the authorization guard. Fixtures now include synthetic
provider IDs while retaining all unknown/denied/mismatched permission assertions.
The generated valid-AAC inspector fixture also failed; its precise reader/file
boundary is still being diagnosed, with no validation guard relaxed. This run is
not green. The lane was explicitly returned for Auto-streaming validation before
any rerun or iOS test. No download candidate installation occurred.

### Native marker diagnosis and candidate correction

A subsequent policy-quality-only Mac run confirmed15/16 passing after the SDK
fixture correction. A bounded synthetic-only inspector run then established the
remaining rejection: AVAssetReader returns49 AAC samples followed by a
zero-sample, zero-byte marker (invalid presentation timestamp, zero duration).
The previous sampleCount>0 guard incorrectly rejected that control marker.
Apple's AVAssetReaderOutput.h documents that compressed outputSettings=nil can
produce marker-only buffers identified by zero sample count, which clients may
skip when their attached metadata is unnecessary. See also
[AVAssetReaderOutput](https://developer.apple.com/documentation/avfoundation/avassetreaderoutput).

The correction skips only zero-sample/zero-byte buffers and continues reading to
real EOF. It retains nonempty media, finite timing, continuity, byte ceiling,
completed-reader status, full duration and all format checks. An additional native
fixture verifies a complete1-second AAC file still fails a2-second expected
source duration. Temporary diagnostic prints were removed. The corrected runtime
candidate has not yet been rerun; no broader success or installation is claimed.

Owner quality-UI steering: quality selectors belong to iOS system Settings, without
a duplicate Profile Downloads section. The added in-app selector has been removed.
Mac has no new download-quality control; Original remains its default. Shared
conversion backend behavior is retained without deciding a new Mac download policy.

### Focused validation and connection-policy integration

Isolated runtime source `38f6e676a8f02fc554954932dfe82790ab6a16fc` passed
focused Debug Mac101 and iOS103 tests (one existing iOS simulator Data Protection
skip). Quality backend17 passed on both platforms, including native valid AAC,
truncation, wrong container and wrong expected duration. Account cleanup, original
transport, manager and offline tests also passed. These are focused checks, not
full suites, Release or physical acceptance.

The download commits are now reconciled in a new integration based on pending
connection-policy211 source `0e1a334ca03893146d5f640dc1675b00e8edfe4d`.
Its six backend/manager/transport source and transport-test files match the tested
isolated source exactly. Preference additions coexist with connection-specific
streaming preferences; the211 connectivity and Profile files are unchanged. iOS
system Wi-Fi/cellular streaming specifiers are unchanged; only the Downloads
specifier is upgraded. Mac streaming remains Original. No Mac download-policy
control or new policy is inferred.

The worktree name212 is a future plan, not an installed/version identity. Its
project still says211. The combined source has not been compiled/tested. Final211
source corrections must be reconciled before assigning a new version, then full
Mac/iOS suites and focused production Release coverage must run serially. A normal
shipping Release build must omit testability/exclusion overrides and pass the
exact-build verifier. Signed installation and physical Original/AAC download plus
concurrent HLS playback acceptance remain separate gates. No publication occurred.
