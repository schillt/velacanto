# Skip delivery comparison — local candidate

> Historical development record. Candidate-stage status below describes that
> checkpoint, not current availability. The 0.5.0 integration includes the accepted
> HLS, quality/download and modern Mac credential work; see the authoritative
> [0.5.0 acceptance and release record](0.5.0-acceptance.md) for current scope,
> superseding evidence and pending publication/TestFlight gates. Earlier DEBUG-only
> restrictions and “not installed” statements must not be read as current policy.

## Authority and base

Owner authorized the controlled comparison on 2026-10-22, with reliability taking
precedence over original encoding when a benefit is demonstrated. No shipping
policy change, broad retry, cooldown, player replacement, or remote publication.

Base: origin/alpha `443e427cbf5b72f892e46f52e51cb8e4257d76e0`. This contains
Alpha182 protection runtime `46aefa9`; shared admission, optional-content isolation,
queue behavior and AVPlayer ownership remain intact. The separate124 investigation
lineage is not merged into this candidate. Existing worktrees/artifacts are preserved.
The phone was read as0.4.0(124.12). Owner explicitly waived repeating the historical
baseline on October22. Its recorded101-second failure remains evidence, not a new
matched test of this source. Initial182 acceptance is not exhaustive validation.

## Implementation

Debug Settings offers Existing delivery (default), AAC HLS,320kbps requested,
and the later MP3 copy-only experiment described below.
Selection changes apply only to the next remote resolution. Downloads retain their
existing local-file leases. Release excludes the selector and HLS negotiation.

Existing delivery retains the UniversalAudio URL and native-format list, with no
new negotiation request. HLS performs one PlaybackInfo POST, disabling direct play,
direct stream and audio stream copy, with an AAC/TS/HLS profile. This additional
round trip is part of measured startup and a comparison confound, not hidden cost.
Server bitrate limits are preserved;320kbps is a request, not a measured output.
The initial candidate did not offer remuxing. The later MP3 copy-only experiment
remains unverified on the deployed server until its actual encoding is inspected.

The resource descriptor keeps delivery intent, media-source identity and negotiated
server session separate from queue/listening occurrence identity. Reports retain
those server identities for HLS; baseline reporting remains unchanged. Returned
playlists must match the requested API-relative audio master route and the negotiated
source/session/device. Cross-origin URLs, fragments and ambiguous identities fail
closed. Credentials and identities are never added to diagnostic output.

HLS retirement enqueues one idempotent, exact-session DELETE after existing native
retirement. Cleanup has one active operation,32 pending,10-second queued expiry,
and uses the existing8-second bounded transport. Saturation/expiry is logged and
not retried. New playback never awaits network cleanup. A returned DELETE does not
prove a late native request cannot restart old work. Dropped cleanup or remaining
server jobs are failed/inconclusive experiment outcomes, not successful teardown.

Debug observations include monotonic selection timing, requested delivery and at
most8 access summaries per selection plus a retirement summary. Access-log bytes
are snapshots, not proof of bytes transferred after cancellation or HTTP task
completion. No URL, personal media name, source ID, session ID or credential is
logged. Retired callbacks retain the captured generation attribution.

## Controlled physical matrix

Use the same phone, Wi-Fi/Tailscale path, remote tracks, route and foreground state.
Keep at least25 upcoming occurrences; do not use downloaded songs for this matrix.
Rotate Existing/AAC-HLS order between repetitions. Within each supported mode,
repeat normal Next and bursts of5,10,20 Next actions approximately200ms apart three
times, leaving the final selection untouched. Record actual action timing.

For each trial retain a sanitized row:

| Trial | Build | Requested / verified delivery | Skip count / interval | Audible start ms | Native start ms | Outcome | Outstanding transfers/jobs | Server CPU/RSS/temp storage | Client memory |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Pending | Pending | Pending | Pending | Unmeasured | Unmeasured | Not run | Unknown | Unmeasured | Unmeasured |

Verify the deployed Jellyfin/FFmpeg versions, master/media playlists, segment MIME
and encoder command before labelling a delivery mode verified. Keep raw credential-
bearing data local; publish only whitelisted aggregates. Distinguish proxy request
arrival from completion. Capture connection/server evidence across abandonment;
a missing completion entry does not prove no request arrived.

Target audible startup about2s after final skip; any load failure or >5s is an
investigation trigger. At a stall, preserve app/VPN state and time a fresh Safari
request on the same phone/path. Stop after the first prolonged failure for evidence.
Do not infer audibility from player state. Compare normal Next separately from bursts.

Acceptance requires3 passes per sequence plus30minutes mixed playback, seeking,
natural advancement, background, Now Playing and affected AirPlay behavior. Record
all startup measurements, cleanup drops and resource trends. No stable memory or
server-cost claim without measurement. A finite pass is not proof of root cause.

## Checkpoints and unresolved gates

- Initial Mac build passed; first512 tests passed before bounded cleanup changes.
- Subsequent515 Mac tests passed with bounded cleanup and negotiated reporting.
- Final Mac run passed516 tests, zero failures. iOS run passed528 tests with one
  skip and zero failures before the final diagnostic-generation attribution edit;
  that edit is included in the final Mac run and device compilation.
- Mac/iOS Release builds and diagnostic-exclusion verification passed. Independent
  code review found no remaining installation blocker after cleanup bounds and
  device/session validation were corrected. Physical acceptance remains separate.
- Signed Debug comparison build uses182.1; existing project/release numbering is
  unchanged. Installation/version0.4.0(182.1) and launch verified on the authorized
  test phone. Audible validation remains pending; no debugger or Mirroring was used
  for launch. Existing124.12 artifact and preinstallation journal are preserved.
- The original signed device artifact verifies. A retained loose copy acquires
  Finder metadata in the document provider; use the metadata-free ZIP for retention
  and reverify after extraction. ZIP SHA256:
  `6c244234cea12501d784f38188c5b1d0ca9d334cbab70c5bd40d6a377c50c2dd`.
- Preflight passed with zero failures; its sandbox signing warning was resolved
  by checking the signing identity with system access. Xcode checks were performed
  separately as recorded above.
- Current server versions/playlist/encoding, proxy correlation and physical matrix
  remain pending. Proxy share is not mounted; Safari automation timed out after
  moving desktops. Dashboard accessibility is owner-reported, not server verification.
- No HLS preference or speculative network repair is enabled. The focused repair
  checkpoint depends on comparison evidence. Preserve rollback124.12 artifact.

Research references (not proof of the deployed version): Jellyfin v10.11.0
UniversalAudioController, StreamInfo and HlsSegmentController show why UniversalAudio
alone cannot guarantee AAC encoding, how session-bearing playlist URLs are generated,
and why cleanup must target an exact session. Apple HLS authoring requirements support
lossless fMP4 audio in principle; deployed Jellyfin remux compatibility is unresolved.

## First HLS compatibility attempt

Owner reports no audio on182.1 in AAC/HLS mode. Captured journal shows two
resolution failures at136ms and121ms after selection, each following a successful
API operation. No native item was installed, so this is a source-preparation
compatibility failure, not evidence of the earlier long native/network stall or
HLS segment congestion. Existing logs do not distinguish response decoding,
capability filtering and playlist validation. The comparison is paused.

182.2 adds only bounded DEBUG booleans/counts and fixed-category rejection stages
for those checks, without logging returned URLs or identities, changing delivery
policy, or relaxing validation. This is a targeted follow-up to the reproduced
failure; actual server support and the required correction remain unresolved.

182.2 regression:516 Mac tests passed, zero failures. Changes are confined to
DEBUG negotiation diagnostics and Release exclusion markers; no delivery or
validation behavior changed. Device build/install verification follows separately.

Signed182.2 device build and signature verification passed. Installation/version
and launch on the authorized phone verified; one HLS attempt requested. Release
exclusion recheck is running. The preserved182.1 failure remains the pre-update
evidence. No fix or HLS acceptance is claimed.

## Playlist identity correction

182.2 Mac/iOS Release builds and diagnostic-exclusion checks passed. Owner's
follow-up attempt decoded one source with HLS/transcoding support, nonempty
session/source/URL, no required headers and no opening/closing requirement.
The app rejected the playlist route before native installation.

Code inspection identified literal route-ID comparison as a compatibility defect:
Jellyfin v10.11.0 StreamInfo.ToUrl appends a Guid ItemId, producing a hyphenated
route; catalog identifiers may be compact. Synthetic regression now covers both
spellings of the same GUID, while rejecting different IDs, malformed GUIDs, encoded
paths, duplicate separators, traversal and relative paths without a root slash.
The correction preserves the returned route and configured reverse-proxy base,
and retains exact negotiated session/source/device validation.

Source: https://github.com/jellyfin/jellyfin/blob/v10.11.0/MediaBrowser.Model/Dlna/StreamInfo.cs

182.3 is the focused compatibility candidate. The captured booleans establish the
route rejection but not its precise raw spelling; physical success after correction
is still needed to associate this defect with the observed attempt. This does not
establish the root cause of the original prolonged skip/network failures.

182.3 verification:517 Mac tests passed, zero failures; focused GUID regressions
and independent read-only review passed. Whitespace check passed. No validation
policy is bypassed and no automatic fallback or retry was introduced.

182.3 signed device build/signature passed; installed version and launch verified.
Candidate source60e47a0. Prior artifacts retained. Owner asked for one remote
AAC/HLS playback attempt; audible and server encoding verification still pending.

## First successful HLS preparation and playback —182.3

Owner reports audible playback within one second. Preserved journal contains two
HLS starts: generation3 at3393ms and generation5 at1086ms from selection to native
playing. Both negotiated and validated the playlist; access logs identify VOD.
Keep both timings: the first exceeds the approximately2-second target, though
neither crosses the5-second investigation threshold. Owner audibility is not
separately mapped to each generation. No average replaces these observations.

This is initial device evidence supporting the GUID compatibility correction,
not acceptance of rapid skipping or proof of the historical stall cause. The
first item's retirement access snapshot reports66 requests and6927800 bytes;
therefore bounded waste/bandwidth improvement is not established. Exact-session
cleanup returned after replacement, without proof of remote job termination.
Actual AAC bitrate, FFmpeg command, server resources and post-abandonment bytes
remain unverified. Next gate: normal Next and a five-skip burst in HLS mode.

## Initial normal Next and five-skip trial —182.3 AAC/HLS

Owner reports near-instant audible startup in all cases. New journal observations:
initial selection generation7:856ms; normal Next generation8:788ms; final selection
generation13 after five Next commands:724ms. Duplicate native-playing observations
are not counted as separate starts. No playback failure or cleanup failure/drop
appears in this captured interval; cleanup requests returned, which does not prove
server process termination.

Measured five-skip inter-command intervals were587,576,560,501ms (approximately).
This passes an initial moderate-speed burst, not the specified approximately200ms
stress condition, nor three consecutive passes. Earlier retired access snapshots
show substantial pre-retirement transfer; no post-abandonment measurement exists.
Next physical step is10 and20 skips near200ms, with sufficient upcoming tracks.

## Mixed rapid forward/backward stress —182.3 AAC/HLS

Owner reports many forward/backward skips and quick playback throughout. Captured
new interval spans18.49seconds, with36 Next,12 Previous and one setQueue command.
Forward bursts comprise26,8 and2 commands. The26-command burst inter-command
spacing is approximately90–135ms; backward navigation comprises12 commands.
This is a substantial unstructured stress pass, not the prescribed three repeats
of separate5/10/20 sequences or a matched delivery comparison.

| Selection generation | Context | Selection-to-native-playing ms |
| --- | --- | --- |
|15|Initial queue selection|1017|
|41|After26 Next commands|1190|
|49|After8 Next commands|1039|
|51|After2 Next commands|988|
|63|After12 Previous commands|1085|

There were49 selection starts and six native installations. Five installed items
reached playing; generation60 was superseded while waiting after about252ms.
Other interrupted selections were replaced before installation.44 API operations
were cancelled,29 succeeded, and no failed API outcome or player failure appears
in the new interval. Six HLS cleanup returns and no cleanup failure/drop were
recorded. Returned cleanup does not prove server encoding-job termination.
Access snapshots report zero stalls; they are not full post-abandonment traffic
measurements. All individual observed starts are retained above. User audible
report applies to the mixed sequence, without per-generation stopwatch readings.

No code change follows this pass. Next discriminating checkpoint is a matched
Existing-delivery run on the same candidate and network, then rotated repetitions
and30-minute mixed playback. Server encoding, resource trends and memory remain
unmeasured; HLS superiority and original root cause are not established.

## MP3 copy-only HLS experiment — implementation pending validation

The owner identified the successful AAC/HLS test's original audio as MP3 and
requested testing original-audio delivery. AAC/HLS deliberately disabled stream
copy; that result does not establish that the source needed conversion for iPhone
playback. Its good skip behavior also does not establish that conversion caused
the improvement.

The next internal option is limited to MP3. It requests an MP3/fMP4 HLS profile
with stream copying permitted, then reads the negotiated master using the existing
playback transport, independently of optional catalog/artwork admission. Only one
local media-playlist variant with `AudioCodec=copy`, `SegmentContainer=mp4`, and
matching source/session/device identity is accepted. That validated child is used
for playback. Missing metadata, another codec, or a server encoding decision stops
the experiment; there is no automatic AAC or progressive fallback. Existing AAC
and progressive options retain their behavior and default selection.

This adds a manifest preflight round trip to the copy experiment. Measure its full
startup cost; do not compare only native buffering time. The parser's64KiB limit
bounds accepted manifest parsing, not transport download bytes. Cleanup retains
the existing exact-session, asynchronous retirement boundary on preflight failure
or cancellation. No second player or queue policy is introduced.

Source review of Jellyfin10.11 shows the master resolves its output audio codec
into the child request and the audio HLS controller supports `-acodec copy`.
That is implementation support, not proof of the deployed server version or its
actual command. Physical MP3/fMP4 compatibility, server FFmpeg command/segment
codec, cleanup, seek/background/routes, and the repeat skip matrix remain pending.
Keep the successful AAC candidate as a comparison, not a new shipping default.

References: [Jellyfin master resolution](https://github.com/jellyfin/jellyfin/blob/v10.11.0/Jellyfin.Api/Helpers/DynamicHlsHelper.cs),
[audio HLS controller](https://github.com/jellyfin/jellyfin/blob/v10.11.0/Jellyfin.Api/Controllers/DynamicHlsController.cs).

Local verification of this implementation:520 Mac tests passed;532 iOS tests ran
with one skipped and zero failures. New cases exercise copy/encoding decisions,
unsafe/multiple playlists, non-MP3 rejection, exact-session retirement, and late
preflight completion after cancellation while optional admission is occupied.
Lint, whitespace review, and preflight passed (the sandbox's signing-identity
warning requires the separate signed device build). Independent read-only review
found no blocking issues in the changed scope. No physical remux acceptance or
root-cause conclusion follows from those tests.

Both macOS and iOS Release builds passed, including identity and internal diagnostic
exclusion checks with the source build number182 supplied to the verifier. Device
comparison artifact will use the explicit build override182.4; installation and
physical acceptance remain separate from these build results.

182.4 signed Debug device build passed from source `a922b09` (build-number override).
Original artifact signature verified; retained metadata-free ZIP SHA256:
`8dd20ca7e35c17e79eb857139bd24d94b95021ee85b5f021a5cc05de633b5625`.
The iPhone13mini's preceding182.3 version was read directly; its journal and prior
artifact were preserved.182.4 installation, installed version and launch verified.
No app data reset, Mac installation, excluded-device operation or remote publication.
The owner was asked to select MP3 copy-only and play the same remote MP3 once.
Audibility, server copy command and subsequent skip validation remain pending.

First owner report after182.4 installation: same MP3 audible within2seconds and
Jellyfin displayed Direct Play. The subsequently captured journal's latest
selection instead reports `directPreferred`, native playing at6101ms, and zero
`player.hls.copy outcome=validated` events. This does not confirm remux selection
or match the audible estimate to that native timing. No copy-only success is
claimed. Asked owner to verify the exact MP3 copy-only setting and start a fresh
remote selection; changing delivery does not alter an already-playing resource.

After explicitly selecting MP3 copy-only, the owner reported playback failure.
Captured182.4 journal: PlaybackInfo decoded successfully, an HLS source and master
route passed validation, then `serverDecision` rejected the child before native
installation; resolution failed at333ms. Exact-session cleanup returned. This is
an experiment compatibility rejection, not the earlier prolonged native/network
stall. The existing rejection does not distinguish audio-codec versus container
mismatch, so neither an encoding decision nor remux impossibility is proven.

The next bounded DEBUG observation records only allowlisted codec/container/copy
flag categories, parsed numeric audio constraints, and source bitrate/sample rate/
channels. Rejection names the field. No raw query values, URLs or credentials are
logged. This does not change negotiation, acceptance, fallback or queue behavior;
it is intended to distinguish the specific server decision on one further attempt.

Decision-diagnostic change:520 Mac tests passed, zero failures; lint and whitespace
checks passed. Changes are wholly inside the existing DEBUG-only comparison block.
The prior182.4 iOS/Release gates remain recorded evidence for that implementation;
they are not claimed as new full-suite runs for the diagnostic-only update.

182.5 signed Debug artifact from `af984f0` built and signature verified. Retained
ZIP SHA256 `7b199b6b8295dccf73ba46acbe16ab87e9f635523fe67cdb559081b5bf4bdc7a`.
iPhone13mini installation, version182.5 and launch verified; app data and prior
artifacts preserved. Asked for one fresh same-MP3 attempt in copy-only mode to
read the decision fields. No behavioral repair or physical acceptance claimed.

182.5 same-track attempt failed before native installation at290ms. Source metadata:
MP3,256000bps,44100Hz,two channels. Resolved child: `AudioCodec=mp3`,
`SegmentContainer=mp4`, `AudioBitrate=320000`; copy flags, sample-rate and channel
constraints absent. Rejected field was audio codec; cleanup returned. The source
bitrate did not exceed the negotiated bitrate. No audio encoding job was observed
or inferred from this preflight rejection.

Further source review found the missed boundary: Jellyfin10.11 StreamingHelpers
sets output audio codec from the request, but calls automatic `TryStreamCopy` only
inside the video-request branch. Allowing audio copy in PlaybackInfo therefore
was insufficient for this audio-only path. This explains the observed unchanged
MP3 codec in the master in the reviewed implementation; deployed server version
remains unverified. It is not the root cause of the original progressive skip stall.

The focused correction explicitly requests `AudioCodec=copy` for the MP3 master
only after validating source metadata against negotiated constraints, retaining
session/source/device and server limits. It continues to reject a child that does
not resolve to copying. No automatic transcode fallback or queue change is added.
Actual FFmpeg copying and iPhone compatibility still require physical verification.
Source: [Jellyfin StreamingHelpers](https://github.com/jellyfin/jellyfin/blob/v10.11.0/Jellyfin.Api/Helpers/StreamingHelpers.cs).

For the explicit-copy correction, a returned child carrying `copy` acknowledges
our explicit request; it is not independent proof that automatic negotiation
selected remuxing. The server command and delivered codec remain the decisive
verification. Constraint checks reject unknown/malformed audio limits, prohibited
copy flags, unsupported codec/container, missing source bitrate, or a source that
exceeds the negotiated cap. Only the master codec parameter is replaced.

Explicit-copy correction verification:521 Mac tests and115 affected iOS library
tests passed, zero failures. Lint and whitespace checks passed. Tests verify the
actual master GET uses copy while preserving320000bps, refusal of incompatible
constraints, and the existing cancellation/cleanup/admission boundaries. All
runtime changes are inside the DEBUG-only comparison block; prior full iOS and
Release checks remain separately scoped to182.4. Physical182.6 validation pending.

182.6 signed Debug build from `deb54f2` passed and original signature verified.
Retained ZIP SHA256 `248b3ff437045b45d69abd270c6bd23fe2640674f0936d40af57e012c3017e74`.
iPhone13mini installation/version182.6/launch verified, preserving app data and
prior artifacts. Owner asked for one fresh same-MP3 copy-only playback attempt.
Audibility, actual FFmpeg command, remux compatibility and skip reliability remain
pending. No remote publication or shipping delivery-policy change.

### MP3 copy parameter compatibility correction (182.7)

Owner reported182.6 unable to play and server version12.2. The captured attempt
rejected preparation at113ms with `masterConstraints/unknownAudioConstraint`;
no native item was installed and targeted cleanup returned. This is an app
validation failure, not evidence of AVPlayer rejecting delivered MP3 HLS.

Reviewed Jellyfin v12.2 source: StreamInfo always adds EnableAudioVbrEncoding
for non-direct-stream URLs and may add TranscodingMaxAudioChannels. The copy-only
validator omitted both. DynamicHlsController's audio copy branch returns before
VBR encoding options are applied. Accept and preserve a unique valid boolean for
the VBR preference; validate the optional transcoding channel ceiling against
known source channels. Continue rejecting unknown audio constraints, ambiguous
or malformed fields, and incompatible source limits. Only AudioCodec changes.
No player ownership, queue, cleanup or production delivery policy changes.

Sources: [Jellyfin v12.2 URL construction](https://github.com/jellyfin/jellyfin/blob/v12.2/MediaBrowser.Model/Dlna/StreamInfo.cs),
[audio copy command](https://github.com/jellyfin/jellyfin/blob/v12.2/Jellyfin.Api/Controllers/DynamicHlsController.cs).
The journal identifies the rejection category, not the exact unknown key; the
standard-parameter omission is independently reproduced by synthetic fixtures.
Actual FFmpeg copying and device compatibility remain unverified.

Regression fixtures now include both standard parameters in full preparation and
cancellation paths, assert preservation in the actual master request, and reject
invalid/duplicate values and insufficient channel bounds. Independent read-only
review found no blocker; its fixture-preservation recommendations were included.

Validation:521 Mac tests passed after the runtime correction. After strengthening
the server-response fixtures,115 affected iOS library tests passed with zero
failures. Lint and whitespace checks passed. Changes remain DEBUG-only; prior
full-platform Release exclusion evidence is not represented as a new182.7 run.

182.7 signed Debug device build from `f11525b` passed. Strict signature verification
passed with system trust access (sandbox-only verification could not evaluate
certificate trust). Retained ZIP SHA256
`8b9f133829a18f0746f98a76857a82aa74b5bf0f7228331b329751c36b844899`.
iPhone13mini installation, version0.4.0(182.7), and launch verified. Existing app
data and prior candidates retained. One same-MP3 copy-only audible check requested;
physical acceptance, FFmpeg command and original skip root cause remain pending.
No remote publication.

### 182.7 physical attempt: native playback failure

Owner reported apparent startup followed by Playback failed. Two captured copy-only
attempts passed negotiation, explicit-copy master GET and child validation. Native
items installed at220ms and188ms after selection. Neither reached ready/playing;
native item failure occurred at10494ms and8136ms. Targeted session cleanup returned
after each failure. These are failed compatibility checks, beyond the five-second
investigation threshold. No audible-success or skip-reliability acceptance.

This moves the observed failure beyond the corrected app preparation guard. The
journal's coarse `nativeItem.other` classification cannot identify HTTP status,
packaging failure or a native decoder error. Copy in the returned URL alone does
not prove successful FFmpeg packaging or delivered media format. Server request
arrival/completion and FFmpeg command/error are still needed before choosing a
repair or declaring MP3 HLS unsupported. No runtime change is justified by these
logs alone.

Safari dashboard now visibly confirms server, web and build version12.2. Logs list
only daily server logs in the current view. Opening today's log and re-inspecting
Safari both timed out in computer automation. The proxy share remains unmounted.
Owner asked to save today's server log and any matching FFmpeg log locally for
correlation. Raw device evidence retained privately. AAC HLS remains the previously
working comparison; production preference and installation stay at182.7.

### Retrieved remux evidence and MPEG-TS comparison (182.8)

Safari Window menu selection recovered control of the existing Jellyfin window;
the log's Download action retrieved the second failed attempt's remux log. Raw
file retained privately. Its timestamp matches the second native failure window.
FFmpeg8.1.3-Jellyfin command used `-vn -acodec copy`, `-hls_time 3`,
`-hls_segment_type fmp4`, start number0. Input/output audio is MP3,44100Hz,
stereo,256kbps. Stream mapping explicitly says copy. No error/invalid/failed line
appears; final summary reports6148KiB audio and0.04 seconds elapsed.
This confirms actual remux execution for this attempt, without proving that the
phone received valid initialization/media segments or accepted their format.
It also shows packaging can finish a whole track quickly; HLS alone does not bound
server packaging work or prove reduced client bandwidth.

Jellyfin web v12.2 has an explicit Safari MP3 HLS MPEG-TS compatibility rule and
an MP3/TS audio profile override because server acceptance of MP3/fMP4 does not
establish client compatibility. This supports a focused container comparison,
not a declaration that all MP3/fMP4 is universally unsupported or that the original
progressive skip root cause is established.
[Client compatibility source](https://github.com/jellyfin/jellyfin-web/blob/v12.2/src/scripts/browserDeviceProfile.js#L534).

182.8 changes only the MP3 copy experiment's requested and validated segment
container from mp4 to ts. Explicit AudioCodec=copy, metadata limits, exact source/
session/device checks, cancellation, cleanup and queue ownership remain intact.
AAC HLS stays unchanged. Fixtures assert the actual profile requests ts, accept
copy/ts, reject copy/mp4 and encoding variants, and retain cancellation/admission
coverage. Physical verification must confirm both audible startup and a server
command using copy plus mpegts. Native compatibility remains a hypothesis until
that check; no automatic fallback or shipping preference change.

Verification:521 Mac tests and115 affected iOS library tests passed with zero
failures. Lint/whitespace checks and independent read-only container review passed.
Runtime change remains three lines within the DEBUG comparison; previous Release
exclusion checks are separately scoped and no new Release run is claimed.

182.8 signed Debug build from `5b229b7` passed; strict signature verified.
Retained ZIP SHA256
`f0ad2f4c3f5563f53f13ab0cbf5d3741a5eb128195aaab91d7dfbcf20db5a57d`.
iPhone13mini installation/version0.4.0(182.8) and launch verified, retaining app
data and182.7 rollback artifact. Same-track copy-only audible check and new server
command verification pending. No remote publication or owner playback acceptance.

### 182.8 audible correction and first-versus-subsequent starts

Owner corrected the initial report: audio eventually started, with a long delay;
only the first track was slow and later selections seemed quicker. Captured
native first-playing observations (not precise audible timestamps):

| Selection | Item installed | First native playing |
| --- | --- | --- |
| Initial182.8 track |795ms|27231ms|
| Following normal Next |226ms|674ms|
| Final selection after23 rapid Next commands |444ms|1223ms|

The rapid burst replaced22 intermediate selections before native installation.
Tap intervals were approximately83–245ms. In the bounded initial-through-burst
window, catalog API terminal outcomes were16 successes,22 cancellations and zero
failures (38 starts); this is not a server outstanding-job count. Initial access
observation at10295ms reported101520 bytes, one request, zero stalls; initial item
stayed unknown/waiting until playing. It is not justified to attribute the entire
delay to AVPlayer's buffer policy: segment delivery and transport timing are
unmeasured. No new runtime tuning or retry added.

Safari download retrieved the initial182.8 FFmpeg remux log. It confirms
`-acodec copy -hls_segment_type mpegts -hls_time 3`, MP3/44100Hz/stereo/256kbps,
zero matching error/failed/invalid lines, and0.02 seconds reported processing
elapsed. Its source identity differs from the182.7 fMP4 failure log: this is
therefore not a strict same-source container-only physical comparison. Actual
MPEG-TS copy playback is demonstrated for this source, while generalized format
compatibility and original skip root cause remain unproven.

The initial27.231-second startup fails the five-second investigation threshold;
fast later starts must not hide it in an average. Next bounded comparison: fully
relaunch only the app, retain Wi-Fi/VPN and delivery mode, then play the same
initial182.8 track. This distinguishes repeatable app-first-start behavior from
a one-off or source/path warming effect without changing another network variable.
No new build, installation or shipping-policy change.

### 182.8 app-relaunch check

Owner fully closed/reopened the app, retained network/mode, and reported the same
previously delayed track audible within two seconds. Journal confirms copy/ts,
256kbps/44100Hz/stereo source, item installed at419ms and first native playing at
1650ms (later duplicate observation1692ms). One access event reports101520 bytes,
one request and zero stalls. Owner attribution to cache warming is a hypothesis:
this check does not identify cache state, server storage wake-up, connection-path
warming or an AVPlayer cause. The27.231-second observation remains in the evidence.
It did not repeat in this single app-relaunch check; no cache purge or new tuning
is justified. Existing182.8 candidate remains installed.

Next acceptance work stays on the same candidate: repeat bounded5/10/20-skip
sequences, record each final selection time and audible outcome, then mixed
playback/queue/seek/background checks. Three consecutive passes per sequence and
30-minute mixed acceptance remain outstanding, along with matched delivery-mode
comparison, client memory and server resource/outstanding-work measurements.
No shipping preference or root-cause conclusion follows from these initial passes.

### Non-MP3 album switch in the MP3-only experiment

Owner identified the album-switch failure as a non-MP3 source. Both captured
attempts rejected at `sourceCodec` during resource preparation (1165ms and2060ms).
Neither installed a native item; targeted cleanup returned for both. This is the
intentional copy-only mode restriction, excluded from MP3 transport/decoder
failure counts. It is still a user-visible failure of this limited test mode;
mixed-format acceptance has not been established.

Before those rejected attempts, the same captured app session records additional
first-native-playing times of1591ms,1110ms and1299ms, alongside the1650ms relaunch
check. Do not infer exact5/10/20 test completion from these observations alone.

Keep the current controlled copy experiment MP3-only for reliability validation.
Do not remove the codec guard or silently transcode to broaden it. Later original-
format support needs explicit codec/container compatibility checks and actual
server-copy evidence per supported format. Existing AAC HLS comparison can cover
mixed formats with intentional re-encoding. No new runtime build or shipping
policy change follows from the non-MP3 rejection.

### 182.8 forward/backward skip sequence pass

Owner reports all requested skip tests passed, including returning to prior songs.
Captured one5/10/20 forward round plus a9-command backward burst. Final native
playing times after the final selection were1277ms,1087ms,1116ms and1537ms
respectively; the owner supplies audible-pass confirmation. Forward burst spans
were0.690s,1.795s and4.203s; backward span1.311s. The bounded post-non-MP3-failure
window contains44 selections and6 native installations, with no native/resolution
failure in that window and19 targeted cleanup completions. These counts do not
prove no outstanding server jobs or bounded client memory.

Before the bursts, replacing the failed non-MP3 selection with an MP3 album
installed the item in188ms and reached playing in8616ms. Owner explicitly directs
that this slow start after a prior unplayable track can be ignored for now. Defer
investigation of that observation for the current MP3 skip acceptance; preserve
it as unresolved, rather than erasing it or attributing it to cache. The separate
initial27231ms observation also remains recorded. Neither is silently converted
into a sub-two-second result. No new playback tuning or diagnostic build.

Current checkpoint: one captured forward matrix round and backward burst passed
with owner confirmation on182.8 MP3-copy/TS. Continue playable-MP3 validation on
this unchanged candidate. Remaining formal gates: two additional consecutive
5/10/20 rounds, sustained30-minute mixed use, queue/seek/background/Now Playing/
route checks where affected, and resource measurements. Original progressive
failure root cause and general/mixed-format policy remain open. Owner deferral is
scoped to the currently observed slow transition, not exhaustive shipping acceptance.

### Owner checkpoint and expanded-format candidate (182.9)

Owner reports enough MP3 testing for this checkpoint, calls playback notably
improved, and reports pauses recovered with buffering. Owner directs expansion
to other formats to enable broader practical testing. Accept this as initial
owner acceptance of the MP3 improvement and a direction to proceed without waiting
for the remaining formal repeat/30-minute gates. Those gates were not completed
or silently counted as passed. This does not prove the original network root
cause, memory boundedness, or exhaustive playback/route acceptance.

The expanded internal mode is named “HLS · original when compatible.” The stored
MP3-experiment preference is retained, so the installed comparison choice follows
into the expanded mode. Existing direct-preferred and forced-AAC comparison modes
remain available; production Release preference remains unchanged.

Intended source policy: copy MP3 into MPEG-TS; copy eligible AAC, FLAC and ALAC into
fMP4; choose AAC up to320kbps/MPEG-TS for other formats or sources lacking sufficient
compatibility metadata. Codec names describe source audio, not file extensions.
AAC source-profile compatibility and FLAC/ALAC support remain device/server test
candidates, not already physically accepted formats. Apple specifies fMP4 for
FLAC/ALAC and xHE-AAC. [Apple HLS authoring specification](https://developer.apple.com/streaming/hls-authoring-specification-for-apple-devices.html).

Audio preparation retrieves source metadata through the playback-owned transport,
then requests one source-specific HLS profile. This necessary audio step bypasses
optional browsing admission. Merely listing several profiles would not select
one by the source codec in Jellyfin's audio path. Bind source and stream identities
and honor any tighter server/user negotiated limits. A preselected AAC path is
conversion policy, not an automatic retry after a failed copy stream. AVPlayer,
queue occurrences, stale-result rejection and targeted cleanup retain ownership.

Copy eligibility is deliberately bounded for this candidate: known positive
bitrate/sample rate/channels, at most50Mbps/192kHz/eight channels; MP3 remains
at most320kbps/48kHz/stereo; FLAC/ALAC require known1–24bit depth; AAC requires a
recognized LC/HE profile. xHE-AAC and missing/unknown AAC profiles choose AAC
conversion pending signaling/metadata verification. The50Mbps ceiling is a
negotiation/test budget, not a requested re-encoding bitrate for copied audio or
a claim of measured network throughput. Tighter server-returned bounds are
validated; an incompatible negotiated response fails rather than overriding it.

Finite single-file sources with one nonexternal audio stream are in scope. Live,
remote-provider or ambiguous multiple-source metadata is rejected. Source drift
between metadata retrieval and negotiation is rejected inside the cleanup lease.
A cancelled POST response can still be discarded by the existing transport before
its session ID is decoded; no native item or segment request has begun there and
AutoOpenLiveStream is false. Do not claim every returned-but-discarded POST ID was
retired. Established preflight/playback leases keep exact-session bounded cleanup.
One necessary metadata round-trip is added to original-preferred startup; forced
AAC remains its prior one-POST path. Server metadata refresh may add further cost.

Expanded-candidate regression checks:525 Mac tests passed; full retained iOS
suite executed537 tests with one existing skip and zero failures. Formatting,
whitespace and preflight checks passed (preflight retains its environment/Xcode-
skip warnings). Independent read-only review found no blocker after tightening
AAC profile eligibility and correcting the held-admission test to wait for the
actual master request. Synthetic adapter cases cover all four copy formats,
unsupported/unknown/out-of-range AAC conversion policy, source drift with cleanup,
metadata cancellation before POST, and child bitrate-limit revalidation.

Both macOS and iOS Release builds at182.9 passed their actual identity and
diagnostic-exclusion checks. A final test-only strengthening asserts the actual
copy master request's codec, container and negotiated constraints; the affected
adapter test passed again on both Mac and iOS. Runtime source was unchanged after
the full suites. Physical expanded-format acceptance and actual server copy versus
conversion verification remain pending installation and owner playback.

182.9 installation checkpoint: signed Debug iPhone build from local source
`7620d3b` built successfully, passed system-trust signature verification, and was
installed and launched on the authorized iPhone13mini. Installed app inspection
confirms0.4.0(182.9). Metadata-free rollback ZIP SHA-256:
`a746dd7086456354139d9c84728624f882aa7fdf99b59ba18e197d1cfbda4382`.
182.8 and its source/artifact remain retained. This is installation verification,
not owner acceptance of expanded formats or publication; no remote source or
release was published. Next check uses the formerly rejected non-MP3 album and
mixed-format playback, then correlates the actual server packaging command.
