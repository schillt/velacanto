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
Use a clean non-synchronized local checkout or isolated worktree for the selected
issue. Do not develop inside iCloud folders. At closeout, inspect committed, staged,
unstaged, untracked and ignored content; integrate useful work, retain only necessary
unique evidence, discard superseded material and remove obsolete checkouts under
the owner's cleanup authority. Leave retained development checkouts clean. Do not
carry dirty or redundant checkouts between rounds; protect unreviewed work during
active development until its disposition is known.

## Owner-approved hosted simulator exception — 2026-11-12

Local VelaCanto iOS testing continues to use the uniquely owned `Velacanto Test Sim`. For the GitHub-hosted `xcode-27` quality job only, the existing workflow may use its uniquely selected available iOS 27.0 iPhone Air. This is a scoped hosted exception, not permission to use another project's local simulator. A prior quality job's metadata identified the GitHub Actions runner group and `xcode-27` label; GitHub documents that label as a hosted image. Verify the actual runner and destination for the exact authorized run; CI environment variables alone do not establish ownership. No hosted run is authorized by this documentation.

## Scope and efficient execution

Through the v1 release, prioritize architecture stability and maintainability,
including reliability and bounded ownership cleanup. Measured performance and
UI/UX improvements are a close second: faster loading, smoother animations and
transitions, and clear, actionable errors and status. Give new features lower
priority until v1. Preserve accepted behavior, existing safeguards and issue
acceptance; reprioritization does not silently close, defer or remove milestone
items. Continue authorized active investigations and raise material scope decisions
with the owner.

Read the selected issue before editing. Execute clear requests without a separate
planning exchange for every small refinement. Batch related visual changes into
one reviewable candidate with a short platform-specific checklist. Separate product
preferences from functional regressions. Ask the owner only for a material decision,
missing authority or interaction evidence that cannot be obtained independently.

When the same symptom survives a fix, collect bounded reproduction, screenshots,
crash or lifecycle evidence before another speculative change. Prove the smallest
supported public-API path before promising parity with Apple's own apps. Preserve
failed evidence; do not assume a platform, network or scheduling cause.

## Engineering standards through v1

Treat correctness, data preservation and understandable ownership as release
requirements. For the current 0.7 round, first address the demonstrated synthetic
reauthentication data-preservation failures under #219/#203, coordinating #30/#179;
physical impact remains unverified. Keep bounded test reliability #201 urgent. Owner deferred unfinished
playback-URL privacy #25 to 0.9.0 on 2026-11-12; preserve its documented
operational redaction and retention guidance. Use reliable tests to enable focused ownership
cleanup, then measure and improve performance and UI/accessibility. New feature
work remains lower priority. Do not infer that this ordering completes, discards
or expands any existing issue, or that a code-review score is release acceptance.

Before changing a path, identify its owner, affected invariants, failure outcome
and smallest meaningful verification. Prefer cohesive functions and concrete,
narrow boundaries over shared mutable state, duplicated lifecycle wiring or a new
generic framework. Refactor around a demonstrated responsibility or change risk;
file length, naming style or a preferred architecture alone does not justify a
rewrite. Keep unrelated cleanup out of the candidate.

For authentication, replacement and deletion, separate preparation from the point
at which ownership or durable state changes. Preserve current data while an
operation is pending, fails or is cancelled; destructive cleanup needs the
applicable authenticated scope and user intent. Preserve successful sign-out's
explicit cleanup contract and pending-upgrade quarantine. Validate identity before
irreversible work, not only after an await. Return structured partial outcomes
where callers need them; never convert incomplete cleanup into reported success.

Give tasks, subscriptions, permits, continuations, files and playback leases an
explicit lifetime owner. Define cancellation and retirement ordering, reject stale
results, and drain or release held work where the contract requires completion.
Cancelling a task is not proof its resources have retired. Keep sharing and
cancellation scoped so one consumer cannot cancel another consumer's valid work.
Bound input size, parsing, queued demand, concurrency and retained storage; test
relevant limits and failure paths without weakening playback protection.

Keep potentially expensive I/O, encoding, decoding and catalog projection out of
UI-critical execution where evidence justifies it. An async function or Task does
not itself move work off the main actor. Measure the actual path before choosing
an optimization; preserve serialization, write ordering, durability, account scope
and cancellation when changing execution context. Do not replace a measured cost
with speculative caching, retries, polling or background infrastructure.

Use deterministic event/condition acknowledgements with elapsed-time deadlines in
async tests. A yield count is not a time bound. Release held operations on success,
failure, timeout and cancellation; preserve strict assertions and original failed
evidence. For a critical regression, verify that its test is included in the
applicable scheme and quality entry point, not just present in the source tree.
Keep compiler and formatting checks strict; do not grow a debt baseline, suppress
warnings, skip a failure or lengthen all deadlines to obtain a pass. Repair the
owned findings or record an explicit owner disposition for unrelated blockers.

For each changed behavior, run proportionate focused checks and applicable
integration/package checks on the exact candidate. Report source observations,
synthetic tests, measured runtime results and physical acceptance separately.
Performance evidence names the artifact/configuration, workload and comparable
before/after result; absence of a measurement is not proof of speed or a diagnosed
cause. Review user-visible errors for an honest state and useful next action,
without exposing implementation details or private data. Carry these standards
into each milestone through v1 using existing issues before creating duplicates.

## Project coordination and issue ownership

The GitHub Project board is the source of truth for development tracking across
turns. At the start of work, read the live board and the selected issue, including
its latest comments. Reconcile status with actual work: queued work is Todo,
active implementation or investigation is In Progress, review-ready work with
supporting evidence is Ready for Review, and Done requires actual acceptance and
owner approval or explicit disposition. Planning alone is not active implementation.
Do not silently close an issue, mark unverified work complete or move unrelated
items just to clear a board. Owner direction and live issue contracts continue to
govern scope and acceptance.

Every feature, bug fix or issue being worked on has a named implementation-owner
subagent. The main agent acts as coordinator: assign issue scope and file ownership,
manage dependencies, integrate and audit the resulting work, coordinate validation,
update the board and issue comments, report to the owner and request feedback on
material choices or acceptance. Do not have the coordinator replace the implementation
owner. Reuse existing Implementation, Acceptance and Auditor assignments when present;
use bounded parallel workers only for independent scope, keep integration serial and
avoid unnecessary review passes. If a required subagent is unavailable, report that
limitation rather than silently bypassing this ownership model. One coordinator
controls the serialized Xcode, simulator and physical-device lane; delegated execution
must not overlap it. No historical worker reservation carries into a new round.

When work is ready for owner review, present a concrete candidate with its scope,
source identity, checks, remaining gaps and any requested acceptance; distinguish
implementation completion from owner approval. Move the issue to Ready for Review
and keep it open while approval is pending. The owner can approve it or return it for
revision: move it back to In Progress, route feedback to its implementation owner,
coordinate the revision and proportionate revalidation, update tracking, and present
the revised candidate again. Do not infer approval or publication permission from
elapsed time, passing tests, or board status.

For each active issue, the coordinator keeps the Project item current and posts a
sanitized issue comment when work starts, at meaningful progress or handoff points,
and when it completes, pauses or is blocked. If new feature or bug work lacks an
issue, create or identify its issue and add it to the Project before tracking progress.
Comments state the assigned scope, local candidate or published SHA where applicable,
actual checks and platform, limitations, blockers and next action; distinguish local
work from published source and unperformed acceptance. Read back remote writes. Keep
credentials, private server/media/account/device information, raw logs, signed
artifacts and private evidence out of the public Project and comments. If GitHub or
Project access prevents an update, report the precise gap and reconcile it when
access is restored. Use the GitHub Project's status update function for concise,
sanitized project-level summaries at meaningful milestones, blockers, decisions,
review handoffs and revisions; do not substitute these for issue comments or post
routine unchanged updates. Describe progress, next actions and owner decisions needed,
including the status and limits of acceptance. Read back updates and use the actual
available status options. Status and tracking updates are authorized; they do not
authorize source publication, release promotion, distribution or device resets.

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
