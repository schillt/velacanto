# Development acceptance

Applies to local v0.6 development. The owner directs the round through the
[0.6 plan](0.6.0-plan.md). This contract separates implementation, review,
acceptance and delivery; none substitutes for the others.

## Before implementation

- Record the issue, expected user outcome, exact base SHA, owned paths and
  dependencies. Inspect current behavior before treating historical feedback as
  a present defect. Preserve already accepted functionality.
- Use one isolated topic worktree per issue. Coordinate overlapping paths,
  integration and the serial Xcode/simulator/device lane. Preserve existing apps,
  identities, credentials, data, archives and unintegrated work.
- Identify account/privacy, remote-input, persistence and playback boundaries.
  Read applicable guides, the security policy when approved, and the
  [playback contract](playback-protection.md) for affected async work.
- Record the current remote development branch. The v0.6 initial local base was
  beta `8d69179180f5f549d012ec11614e98c180e63080`, whose tree matches v0.5
  `62982bb`. Alpha was absent at intake, then restored; current fetched alpha is
  `371cec970593bc464ff03d1042e2c94b91ff999a`, adding only permanent-branch guidance.
  Reconcile that guidance before local integration; no beta/main change follows
  from development.

## Review and verification

| Change | Evidence required before acceptance |
| --- | --- |
| Documentation/policy | Complete diff, relative-link and consistency checks; distinguish factual current behavior from proposed rules and future features. Legal/user-policy drafts require finalized publisher/contact/scope and approval before public use. |
| Native interface | Reproduce or state the reproduction limit; focused rendered interaction checks; relevant light/dark/text-size/platform states; semantic accessibility and actual physical assistive-technology checks where affected. Screenshots alone do not prove usable accessibility. |
| State, async or mutation | Meaningful production-seam tests for success, failure, cancellation, late/stale work, duplicates/identity and account retirement. Use bounded observers and deterministic acknowledgements, not relaxed assertions or deadlines. |
| Shared loading/artwork | Saturation, protected progress, shared promotion, cancellation/cleanup and cached independent publication; exact-candidate physical playback while browsing/expanding Now Playing/changing tracks/seeking. Audio never waits on optional content. |
| Playback/transport/quality | Relevant local suites and signed checks; exact installed candidate with owner-confirmed audible outcome, seek, queue, background and affected routes/formats. Do not infer audibility from a timer or native Playing state. |
| Credentials/storage/privacy | Source/data-flow review, account separation, coherent failure/cleanup, signed identity/entitlements, supported Keychain and file-protection checks. Distinguish local deletion, backups, server revocation and server logging. |
| Cross-device/provider | Minimal validated/versioned payloads, receiving account authorization, unavailable/disabled/offline and stale/duplicate handling; applicable actual device/server acceptance. |
| Release/configuration | Validate actual produced app/extension metadata, identity, signature/profile, dependency pins, DEBUG/test exclusion, privacy/export declarations and artifact hashes. Source plists and inherited results alone do not validate the new artifact. |

Run focused local checks during development and relevant platform/full/Release
checks at integration. Do not dispatch hosted release gates for routine patches.
Host-orchestrated UI cases must be explicitly opt-in, with execution versus skip
verified in the result. Keep ordinary suites independent of an external operator;
restore any controlled simulator appearance after the case, including failures.
Keep builds/tests serialized on existing authorized destinations; do not create
extra simulators, overwrite references or use the excluded physical iPhone 17 Pro.
Real server mutations require an authorized disposable test scope.

## Security and privacy acceptance

- Review the actual changed trust boundaries. No token, private origin, full
  authenticated URL, personal media, stable device/account identifier or raw
  trace belongs in public source/evidence.
- Do not weaken HTTPS/certificate validation, credential storage, account cleanup,
  resource budgets, release exclusion or user consent to make a test pass.
- Modern Mac credentials never read/migrate/delete/fall back to the legacy store.
  Preserve pending-reauthentication data; do not approve unmatched-scope deletion
  on the owner's behalf.
- An existing accepted limitation remains explicit. The token-bearing media URL
  concern is still open; Keychain/HTTPS do not establish its remediation.
- A security-policy document is guidance, not a completed scan or a finding
  waiver. An empty privacy manifest collection array is not proof that servers,
  Apple or support channels process no personal information.
- User-facing disclosures must match the shipped feature set. Handoff, iCloud
  pin sync, additional providers and local indexing are not active merely because
  their plans exist. Update privacy/export analysis when those features change.

## Independent review and disposition

The implementation owner supplies exact base/final commits, changed paths,
commands/results and pending gates. A separate acceptance/review pass examines
the exact candidate and records actionable findings. Shared GitHub identity does
not count as a different-account approving review.

Use P0/P1 for critical or release-blocking findings with stated impact, P2 for a
normal correction/investigation and P3 for polish. Distinguish confirmed defects,
hypotheses and missing evidence. Resolve findings or obtain explicit owner
disposition; do not silently convert pending checks into passes. Preserve failed
attempts and make only diagnosed, justified reruns.

Each criterion is **pass**, **fail** or **pending** with: issue; source/build;
platform/route; ordered actions; debugger/Mirroring state where relevant; result;
owner-confirmed audible/server outcome when required; limitation; next owner.
Synthetic tests, local installs, accepted behavior and distribution are distinct.

## Integration and delivery

Integrate reviewed local commits serially onto a verified current base; rerun
affected checks after conflicts or dependency changes. Inspect explicit staged
paths and full diffs before committing. Publish only through the approved shared
branch workflow, without force-push or publishing any local task branch refs.
GitHub alpha, beta and main are permanent: never delete, rename, replace or retire
them, including after promotion. Verify all three expected heads before and after
promotion. All codex/* and other local topic/worktree branches stay local, without
remote-review/CI exceptions. Preserve historical remote refs unless separately
authorized cleanup is assigned. Follow the fetched root guide for recovery of a
missing permanent branch without rewriting surviving branches.

Freeze an owner-selected release candidate before hosted quality, promotion,
tagging or distribution. Record source, toolchain, version/build, signing and
hashes, required/advisory checks, signed export, upload, processing and actual
tester availability separately. Automatic TestFlight delivery remains main-only;
preserve the owner's authorized manual Cloud path and existing tester scope.

Before release, release promotion/tagging or distribution, inspect the live
milestone and every issue page. Every issue must be completed and closed with
acceptance evidence, explicitly moved to a specific later milestone with active
Project tracking reconciled, or explicitly discarded with a reason and removed
from current milestone/active tracking. Unresolved disposition decisions block
release; local plans, implementation and previous delivery authorization do not
clear the gate. Never move, discard or close unfinished issues to bypass it.
Record the dispositions, check time and remaining issue count, and recheck live
state immediately before release. Ordinary local development remains allowed.

Do not claim completion of a milestone or App Store/legal compliance from code,
a passing build, a policy draft or source publication alone.
