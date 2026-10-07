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
