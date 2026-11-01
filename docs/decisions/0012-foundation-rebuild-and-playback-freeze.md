# 0012 — Foundation rebuild, retained architecture, and playback freeze

- Status: Accepted
- Date: 2026-09-05

## Context

The legacy recovery candidate failed physical acceptance despite local gates.
Recorded failures establish amplification but not the initial stall's cause.
The owner approved a minimal native rebuild, then reported successful basic
playback and successive UI additions. This does not prove every failure path
or isolate simplicity as the only causal variable: streaming format and request
mix also changed. The owner explicitly freezes working playback while UI returns.

## Decision

Retain ADR0001 shared core/native Apple surfaces, ADR0004 asynchronous source
resolution and resource ownership with one playback authority, and ADR0008
neutral catalog/capability boundaries. Provider connection UI stays specific.
The original UI remains the design reference; old controllers are not a template.

The Foundation player uses one AVPlayer/current item and releases the previous
item before replacement. Its engine, stream URL policy, native transport setup
and audio session are frozen during UI work. Any necessary correction gets an
explicit rationale and owner review. The richer resource-lease handoff in0004
is deferred for external files, not rejected; retain open-in-place semantics.
Do not reintroduce legacy candidate slots, preroll coordination, cooldowns,
session retirement, admission/recovery managers or automatic retries by default.

ADR0011 retains its principles: bounded visible work, account isolation,
cancellation ownership, local failures and honest request evidence. Its mandated
shared admission/coalescer/semantic cache/retry mechanisms are superseded for
NativeFoundation only. Existing native transport and simple page ownership are
the baseline; additional machinery requires demonstrated need and an amendment.
Legacy code remains preserved evidence, not silently rewritten.

Jellyfin is the sole implemented server provider. Keep identifiers opaque outside
its adapter; never put provider-name switches or endpoint assumptions in shared
playback/UI. Do not implement another provider or a universal framework merely
to preserve extensibility. Unsupported actions stay honestly disabled.

## Delivery and platforms

Parallel workers use non-conflicting owned files and exact isolated local bases.
The coordinator integrates and installs serially; the owner tests one candidate
at a time. iPhone and macOS are first-class, with native touch/pointer/accessibility
controls. Source/compile tests do not substitute for exact-device acceptance.
A tested local lineage must be reconciled explicitly with GitHub alpha; do not
push accumulated unreviewed legacy commits or replace tested sources silently.
GitHub updates preserve historical issue evidence and separate source publication
from device/release acceptance. Promotion remains alpha → beta → preview → main.

## Consequences

UI can progress concurrently without destabilizing the proven core. Some advanced
queue and local-file operations remain unavailable until separately approved.
Each new control layer must demonstrate necessity; deletion is preferred when
it preserves behavior. Earlier date-based delivery plans no longer establish
acceptance. No reliability percentages are inferred from small successful runs.

## Scoped amendment — artist detail reuse (2026-10-14)

The owner approved bounded account-owned reuse after review identified duplicate
artist detail requests from branding, overview and favorite observation. One
32-entry, 60-second memory memo now coalesces those identical reads; failures are
not cached. Incoming image revisions and favorite mutations revoke stale reuse
without interrupting existing branding/overview consumers. Last-consumer exit and
account retirement cancel outstanding work. Existing transport, artwork admission,
player ownership and explicit retry remain authoritative; this does not authorize
a general request scheduler or automatic retry layer. Artist songs receive initial
loading priority over optional metadata. Existing shimmer remains by owner choice.

## Scoped amendment — playback and Now Playing protection (2026-10-14)

The owner authorized implementing protection after reporting silent playback with
continuous loading alongside incomplete expanded-player artwork. Only playback
and Now Playing receive preferential admission. Artist, Album, Home, New, Library,
Search and playlist browsing remain equal, with bounded parallel loading and
independent publication of completed sections. Cache hits do not wait for network
admission. Requests required to fulfill an explicit Play action are playback work.

The scope permits account-owned admission at existing catalog/artwork boundaries,
driven by existing playback state, and current-artwork recovery corrections. Audio
delivery remains owned by AVPlayer and never waits for an artwork/catalog permit.
Protection constrains new browsing work during startup/buffering without cancelling
all useful requests or introducing an indefinite browsing blackout. Cancellation
and account retirement must release queued demand safely.

This exception does not authorize a replacement player, transport, watchdog,
automatic retry loop or revival of legacy managers. Successful unit tests/builds
do not establish the cause of the reported silent spinner or prove physical audio
recovery. The exact candidate requires playback-under-load acceptance separately.

The durable behavior, implementation limits, review gates and lessons from
Alpha182 are specified in [Playback and Now Playing protection](../playback-protection.md).
The owner reports initial testing passes; this is an acceptance checkpoint, not
proof of the earlier stall's root cause or exhaustive route/background validation.
