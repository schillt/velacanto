# VelaCanto agent instructions

## Current authority and starting point

Current owner instructions, live issue contracts and their latest relevant comments
govern the work. Development is now **0.7.0**, tracked in
[milestone 7](https://github.com/schillt/velacanto/milestone/7). Read the
[current handoff](docs/0.7.0-agent-handoff.md), the nested native guide and
[playback protection](docs/playback-protection.md) before changing shared behavior.
Older release plans, build records and worker reservations are historical evidence,
not active assignments. Do not resume an old worker or release checklist by default.

The maintained app is `NativeFoundation/VelacantoFoundation.xcodeproj`, scheme
`VelacantoFoundation`, using Xcode 27. Product spelling is **VelaCanto**. Preserve
target, bundle, Keychain and storage identities. Canonical distribution naming is
VelaCanto; local validation may use VelaCanto Alpha. Publisher documentation uses
**NovoLuxor**, `support@novoluxor.dev`, United States; privacy and terms remain drafts.

At startup, verify live `alpha`, the checkout/branch/full SHA and dirty state. Keep
installed runtime, published source and Apple distribution identities separate.
Preserve older dirty/unpublished work; use a clean non-synchronized local checkout
or isolated worktree for the selected issue. Do not develop inside iCloud folders.

## Scope and efficient execution

Read the selected issue before editing. Execute clear requests without a separate
planning exchange for every small refinement. Batch related visual changes into
one reviewable candidate with a short platform-specific checklist. Separate product
preferences from functional regressions. Ask the owner only for a material decision,
missing authority or interaction evidence that cannot be obtained independently.

When the same symptom survives a fix, collect bounded reproduction, screenshots,
crash or lifecycle evidence before another speculative change. Prove the smallest
supported public-API path before promising parity with Apple's own apps. Preserve
failed evidence; do not assume a platform, network or scheduling cause.

Reuse existing Implementation, Acceptance and Auditor assignments when present.
Keep file ownership explicit and integrate serially. Use bounded parallel workers
only for distinct independent scope; do not create extra chats or review passes
for routine patches. One coordinator owns Xcode, simulators and physical devices.
No historical worker reservation carries into this round automatically.

Run focused tests for changed behavior, then the applicable integrated iOS/macOS
build and package checks. Reuse scoped acceptance unless a changed path or new
regression warrants another check. Preserve assertions and deadlines; no arbitrary
sleeps, skipped failures or privacy weakening to make tests pass. Poll the same
live process handle; a timeout is not completion. Report actual platform/count/scope;
an owner pass with an unspecified platform stays unspecified. Device installation,
audible playback, accessibility, server behavior and distribution are distinct.

## Publication and closeout

Preserve permanent `alpha`, `beta` and `main`; never delete, replace, force-push or
rewrite them. Temporary task/worktree refs stay local. The 2026-11-02 preparation
authorizes reviewed documentation/instruction and tracking updates to `alpha`.
It does not grant standing publication of future implementation, beta/main
promotion, tags, Cloud builds, TestFlight or App Store submission. Continue locally
until the owner authorizes the relevant next external action.

Before release freeze/promotion, inspect the actual delivery entry point, selected
branch/SHA, configuration, entitlement selection and required CI/scanner toolchain.
Native Xcode Cloud archives may not run a local archive script. Surface blockers
before the final gate. Gate the exact frozen candidate, including amendments.
Security exceptions need explicit owner approval for that candidate and remain
exceptions. Stop on protection rejection; do not weaken a rule or publish a task
branch as a workaround. Source publication, signing/export, Apple processing and
tester availability require their own evidence.

Audit every page of the live milestone before release disposition. Record accepted
scope, explicit carry-forward or an owner-approved discarded item; never silently
check historical criteria or close issues just to clear a gate. At closeout, update
the existing current handoff/checkpoint after remote readback: exact source, changed
paths, checks, acceptance, remaining work and next owner. Remove completed actions
from the active next-step list; keep their historical evidence in release records.

## Runtime and privacy invariants

Keep one existing player/queue and the native activation/continuation owners.
Audio and Now Playing never wait for optional browsing or artwork. Only actual
playback/Now Playing receive preferential admission; browsing remains bounded,
equal and independently published. Preserve cancellation, occurrence identity,
account retirement and rejection of stale callbacks. No new player, generic
retry/polling/watchdog framework, hidden whole-catalog scan or speculative provider.

Preserve native appearance/underlap. End-of-scroll clearance must not become an
opaque overlay or clipped viewport. Related sheets respect system appearance.
Continue Listening remains remote-only, using the existing media card and one
song/usable-reported-queue action. Dismissal hides the card without stopping audio.
Non-native source stopping is best effort after receiver start and a matching-source
recheck; retain native Handoff safeguards and never silently truncate occurrences,
invent missing shuffle state or transfer credentials. Show Handoff guidance only
on clients/platforms that can use it.

On 2026-11-02 the owner accepted Production pin sync as working, with residual
iCloud delivery lag considered Apple-managed and no actionable app defect reported.
Do not reopen #198/#218 or add polling/retry work solely for that accepted lag.
Reopen only for new evidence of an app-controlled regression. Keep runtime opt-in,
account isolation, local availability, merge/deletion rules and existing identities.
Release selects Production entitlements/container; Debug/UITesting stay unconfigured
unless explicitly overridden for Development testing. Owner acceptance is not an
independent archive/profile audit or blanket edge-case pass.

Validate account/source ownership and server permissions before async results or
mutations. Keep modern Mac Data Protection Keychain and no legacy access/migration
or fallback. Local-file work remains unfinished and hidden until its actual scope
is accepted; do not confuse it with working offline Jellyfin downloads.

The repository is public. Read `SECURITY.md` and `docs/publication-safety.md`.
Stage explicit reviewed paths only, never broad `git add .`/`git add -A`.
Keep credentials, private server/media/account/device details, profiles, signed apps,
raw traces, receipts, generated Xcode state and Cloud manifests out of commits.
Keep build output and detailed evidence on non-synchronized local disk. Preserve
historical archives, installed apps and data. Legal drafts are not effective agreements.
