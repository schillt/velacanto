# Velacanto agent guide

## Authority and current product

GitHub `schillt/velacanto` is the shared source of truth: integrated source,
versioned project instructions, issues and their latest relevant comments.
Projects and milestones track delivery status; they do not override the issue
contract or prove integration. Fetch `origin/alpha` before starting current
implementation. Local notes, chat summaries and unpublished plans are working
material, not integrated dependencies. Record approved changes in GitHub through
the workspace maintainer so every worker receives the same contract.

This owner-approved workflow supersedes historical direct pushes to alpha,
local-only issue branches and mandatory alpha → beta → preview → main promotion.
Do not follow those older instructions from archived documents or stale worktrees.
Current owner instructions can change scope; reconcile their approved contract in
GitHub before dependent work begins. Do not silently promote unpublished plans.

Before editing, compare the fetched alpha guide, applicable nested guides, current
owner instructions and the issue contract. Check that board workflow descriptions
agree. Report material conflicts before dependent work; never replace a dirty
checkout's instructions to make them appear current. Explicit owner instructions
take precedence, but a scoped exception does not permanently change the default
workflow. Record its scope and reconcile shared documentation.

Velacanto 0.4.0 development follows the 0.3.5 and 0.3.0 (108) Foundation line.
Read `docs/0.4-development-record.md` and `docs/0.4-plan.md` for the current
integrated checkpoint and outstanding gates. The maintained
app is `NativeFoundation/VelacantoFoundation.xcodeproj`, scheme
`VelacantoFoundation`, product `Velacanto`. Read `NativeFoundation/AGENTS.md`,
ADR 0012/0013 and `docs/0.3.5-acceptance.md`. Build 107 remains rejected. Historical
0.3.0 freeze documents do not disable the scoped 0.3.5 features. Never restore old
controllers to satisfy superseded plans.

The historical 0.3.5 exception authorized PR #174 into alpha after passing checks,
a GitHub prerelease and existing-workflow internal TestFlight, with documented
known bugs and the native volume slider retained. That exception did not authorize
main promotion. The later accepted preview `de7abe9` was promoted through PR #190
on 2026-10-07; newer 0.4 source is excluded. These recorded release decisions do
not establish that the volume defect is fixed. Record current checks,
exceptions and signed distribution status separately; no public App Store
submission is implied. Do not change runtime/version metadata in planning-only
work. Apply `docs/engineering-rubric.md` to future reviews without inventing grades.

## Roles and parallel delegation

Subagents are authorized for independent, bounded tasks without asking for each
assignment. Delegate when it enables useful parallel progress; simple tasks can
remain with one agent. Delegation does not expand scope or count as acceptance.

- **Implementation agent:** implements one assigned issue per isolated worktree,
  writes meaningful focused tests and hands off exact commits and limitations.
- **Acceptance agent:** independently tests the supplied exact candidate and
  records pass/fail/pending plus reproduction. Does not silently modify the source
  being accepted or invent physical/audible evidence.
- **Workspace maintainer:** maintains project/setup/docs, publishes assigned task
  branches/PRs, coordinates build/device slots and executes authorized merges.
  Does not self-certify product acceptance.
- **Auditor:** reviews scope, design, ownership, privacy, findings and acceptance
  evidence; requests focused corrections and records disposition.
- **Owner:** resolves scope/release decisions and authorizes final merges or
  explicitly delegates that authority. A task assignment alone is not release
  publication or automatic merge authorization.

Each handoff includes issue/subtask, exact base SHA, owned paths, dependencies,
acceptance criteria and privacy constraints. Separate issues use separate
worktrees. Workers within one issue require non-overlapping write ownership;
never edit a file concurrently. Read-only review/research can run alongside
implementation. Resolve conflicts before writes; preserve others' dirty work.
Report completion or blockers promptly to the coordinating agent with the exact
candidate and next owner; do not wait for the owner to ask for status. For a small
patch, use focused implementation, one independent acceptance pass, an integrated
build and the relevant physical sanity check. Repeat gates only for changed scope,
failures or unresolved evidence. Keep runtime candidates local until buildable
and physically sanity-checked unless the owner authorizes earlier publication.

All agents currently using one GitHub account are one GitHub identity. Their
independent reports are useful evidence but cannot satisfy an approving review
from a different account. Never impersonate another reviewer or bypass a required
review. Configure required approval counts only when eligible reviewers exist;
otherwise record agent review and the owner's merge decision explicitly.

## Branches, issues and pull requests

The normal flow is **issue → short-lived task branch → PR into alpha → accepted
release PR into main → release tag/artifact**. Beta and preview are candidate
validation/distribution stages, not mandatory permanent merge branches. Retain
existing beta/preview/recovery branches until explicitly retired; do not delete
history or rewrite them as part of routine cleanup.

1. Read the entire assigned GitHub issue and latest relevant comments. It must
   define Outcome, User behavior, Implementation boundaries, Acceptance criteria,
   Out of scope, Dependencies and Verification. Use P0–P3 priorities.
2. Fetch alpha. Confirm dependencies are integrated and inspect worktree ownership.
   Start one `codex/<issue>-<description>` branch in one clean worktree from the
   current `origin/alpha`; record the full base SHA. Never reuse another issue's
   dirty tree or start dependent code on an unpublished assumption.
3. Implement only the issue contract. Commit only owned files; run focused gates
   and `git diff --check`. Never reset, stash, stage or revert another worker's work.
4. The maintainer publishes the task branch and opens a focused PR **into alpha**,
   linking the issue and recording behavior, evidence and limitations. A draft PR
   is allowed for early review but is not merge-ready. Issue workers publish only
   when specifically delegated that responsibility; no direct shared-branch push.
5. Acceptance and audit review the latest candidate. Update the branch with alpha
   if it has advanced, resolve conflicts in the task worktree, and rerun affected
   verification. Review evidence must identify the current SHA. Material edits
   invalidate affected acceptance and require re-review.
6. Merge ordinary development changes after relevant local checks, resolved
   discussions, scoped P0/P1 disposition and required physical gates plus the
   owner/authorized merge decision. Hosted checks are required only for release
   candidates, as described below. Merge one PR at a time; do not use bypass/admin
   overrides or ignore failed applicable checks.
7. **Squash-merge focused task PRs** into alpha. Record the integrated SHA and run
   affected local integration checks before using it as an accepted dependency.
   PR-head tests are not proof of the integrated commit. If integration fails,
   stop dependent work and submit a focused fix/revert PR; do not hide a repair.
8. Update the issue, milestone/Project and release checklist after actual merge and
   applicable verification. Distinguish code integrated from feature accepted and
   release ready. Delete the merged task branch and clean worktree only after
   proving integration; preserve unintegrated work and evidence.

Do not squash long-lived alpha into main: use a release merge commit to preserve
ancestry. Allow merge commits for release PRs; do not impose global linear history
that conflicts with this release strategy. Do not rebase/force-push shared branches.

## GitHub access and enforcement

Before a GitHub write verify account and repository, without exposing credentials:

```sh
gh auth status
gh repo view --json nameWithOwner --jq .nameWithOwner
```

Use authenticated `gh` for repository/issues/PRs/Projects. Private Project work
requires the relevant repo/project scopes; query field and option IDs rather than
copying stale values. Stop on actual missing authorization or a rejected push;
do not retry blindly, change credentials or use copied tokens/cookies. A sandbox
network failure is not invalid authentication if `gh auth status` succeeds.
A sandbox/keychain restriction can also make that command report an invalid token.
Before asking for reauthentication, verify it in the approved host/network context
using the normal permission mechanism. If it still fails there, stop and report
that actual failure; never extract credentials or work around authorization.

Desired protection on alpha/main: PR required, up-to-date base, resolved
conversations, no force pushes/deletion or routine bypass. Do not require a hosted
`Quality Gate` on ordinary development PRs when it is intentionally release-only.
Enforce the exact-candidate hosted gate at release promotion/publication. Require
eligible independent approvals when available. Until repository settings enforce
these rules, agents must enforce them procedurally and report
that distinction. This file alone does not install branch protection.

Check actual rulesets/protection and required-check names before changing settings.
Do not mark a job required simply because a workflow calls it a gate; do not treat
an advisory failure as success of that advisory. The OS 27 gate is the current
product gate; legacy toolchain advisory status is reported separately. Never
remove tests or make failures optional to merge a change.

## Public publication boundary

The repository is **public**; the development Project is private. A private
Project does not make linked issues, PRs, commits, Actions logs or release assets
private. Follow [Publication safety](docs/publication-safety.md) before staging
or posting. Inspect exact owned paths, stage them explicitly, then review the
staged names and complete diff locally. Never use broad `git add .`, `git add -A`
or force-add ignored local material as a shortcut.

Ignored/untracked files are not tracked release content. Ignore rules do not
remove already tracked files or sanitize history. Inventory local artifacts
without publishing contents or identifying paths; keep deliberate source,
examples and synthetic test fixtures trackable. Review the exact candidate and
intended release artifacts, not the entire private filesystem. Report bounded
categories/counts and limitations, never credentials, private origins, personal
media, stable device/account IDs, raw traces or unnecessary local home paths.

Sanitize issue/PR/comment text before posting: an edit can leave the earlier
value visible in GitHub revision history. If remediation is needed, use GitHub's
revision-removal workflow or an authorized sanitized replacement plus removal
of the old comment; verify the exposed revisions are no longer visible. Do not
quote the value again, rewrite Git history or change credentials without the
separately authorized response. Local review, PR publication and owner-approved
merge remain separate steps; this guardrail grants no publication permission.

Keep publication exposure, runtime data handling and server/proxy logging separate
in privacy reports. State the reviewed snapshots/artifacts, categories and limits;
use “no secrets found in the reviewed scope,” not “everything is sanitized.”
GitHub source archives contain the tracked tag snapshot, not live Keychain or
UserDefaults contents. Synthetic API routes/test fixtures are not evidence of
private data solely because a broad scanner matches them. Review matches locally
before reporting, without copying their contents into public evidence. HTTPS
protects transit; it does not establish safe endpoint logging or local retention.

The current LICENSE makes Velacanto public-source proprietary software, not an
open-source-licensed app. Check the candidate LICENSE and third-party notices;
do not change licensing, grant rights or describe dependencies as covered by the
app's license without authorization.

## Builds, devices and release provenance

Use per-worktree derived data from `./scripts/build.sh`. The maintainer serializes
Xcode builds and simulator/physical tests. Explicitly select an existing authorized
destination using `VELACANTO_IOS_SIMULATOR_DESTINATION`; a script default may be
stale. Keep only the retained iPhone and iPad simulators; do not create more for
parallel testing. Protect original-reference apps and Foundation106. Physical
**iPhone 17 Pro is excluded** from testing and cleanup. Do not overwrite a reference
or delete archives/unintegrated work to make room for tests.

Local checks include `./scripts/preflight.sh --skip-xcode`, `git diff --check`,
lint and relevant tests/builds. Ordinary patches, documentation changes, task PRs
and development integrations use local verification; do not dispatch, wait for or
rerun hosted quality gates for them. Scope verification proportionately for
documentation; runtime/interface changes require relevant regression, platform
and physical evidence. Compiler/test success does
not prove streaming, audibility, signed distribution or accessibility.

Hosted quality gates are reserved for owner-approved release candidates/builds,
including prereleases and hotfix releases. Run them on the frozen exact source SHA
before publication, record the result and rerun only if that candidate changes or
a diagnosed failure requires it. The workflow runs for immutable `rc-*` candidate
tags; creating such a tag requires release-candidate authorization. Manual dispatch
is also supported once the workflow's dispatch trigger is integrated into GitHub's
default branch. Never create a candidate tag just to check a routine patch. A local
Release configuration build is not, by itself, a release candidate. Keep hosted
validation, signed distribution and TestFlight authorization separate.

For physical checks, record the installed candidate, action order, debugger and
Mirroring state, route and user-confirmed audible outcome in sanitized evidence.
If the installed build or intervening actions are uncertain, mark the result
unverified and repeat only the affected check. A defect absent in TestFlight is
an observation, not proof of an SDK/compiler cause or a fix; retain its disposition
until controlled comparison establishes the result. Do not start TestFlight or
release publication merely to verify a local patch.

Freeze an exact release candidate from accepted alpha. Record source SHA,
version/build, toolchain, signing mode, artifact hashes, test results, known issues
and physical acceptance. Label beta/preview candidates with immutable tags/build
identities. Do not move published tags. Any source change produces a new candidate
and invalidates affected evidence; re-signing/rebuilding produces a new artifact
whose provenance must be recorded. TestFlight acceptance names the actual upload.

Open a release PR from alpha into main after full candidate acceptance. Verify
its final integrated source and checks, retain the candidate-to-release mapping,
and tag the accepted release. Build signed artifacts from recorded source and
verify distribution separately; an unsigned CI build is not a TestFlight build.
Keep alpha frozen through release promotion or use a separately approved release
branch strategy if continued development is necessary. Hotfixes use a focused PR
from current main, then reconcile the fix into alpha through a PR before further
release promotion. No routine cherry-pick-only divergence between shared branches.

## Quality, privacy and completion

Prefer one owner per mutable state, explicit task lifetime/cancellation, complete
user-visible async outcomes and small justified abstractions. Apply the reusable
rubric when it is present in the integrated source; never claim local-only rubric
or planning files are canonical. Use P0 (critical), P1 (release blocker), P2
(normal correction/investigation), P3 (cleanup/polish). Separate confirmed defects,
hypotheses and unverified gates; no grade substitutes for acceptance.

Provider-neutral catalog/actions remain the boundary; Jellyfin account UI is
provider-specific. No speculative retry/session-retirement/watchdog/player layer,
offline audio, playlist mutation, CarPlay, new providers or reporting outside the
assigned scope. Keep credentials, origins, full request URLs, personal media and
account/item IDs out of issues, PRs and shared logs. Detailed diagnostics stay
bounded and DEBUG-only; use sanitized aggregate evidence.

Account privacy changes must preserve coherent credential, account-model, task and
account-owned metadata lifetimes, including explicit cleanup/failure outcomes.
Read [Sign-out privacy](docs/sign-out-privacy.md) and
[Pin storage privacy](docs/pin-storage-privacy.md) when changing those paths.
Successful local cleanup does not erase old backups or prove server revocation.
Keep playback credential/delivery changes isolated from account-cleanup patches;
follow [Playback URL privacy](docs/playback-url-privacy.md), use supported Apple
APIs and require seeking, background, queue and AirPlay acceptance before combining
transport changes. Do not replace media delivery speculatively to satisfy an audit.

Final handoff: base and final SHA, PR/issue, owned paths, tests/results, privacy
review, pending gates, integration status and next owner. Report local, published,
merged, accepted and distributed as distinct states. Never mark documentation or
implementation Done merely because a local commit or draft PR exists.
