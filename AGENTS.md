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

Velacanto 0.3.5 follows the 0.3.0 (108) Foundation replacement. The maintained
app is `NativeFoundation/VelacantoFoundation.xcodeproj`, scheme
`VelacantoFoundation`, product `Velacanto`. Read `NativeFoundation/AGENTS.md`,
ADR 0012/0013 and `docs/0.3.5-acceptance.md`. Build 107 remains rejected. Historical
0.3.0 freeze documents do not disable the scoped 0.3.5 features. Never restore old
controllers to satisfy superseded plans.

The owner authorized PR #174 into alpha after required checks pass, a 0.3.5
GitHub prerelease from alpha and existing-workflow internal TestFlight, with
documented known bugs and the native volume slider retained. No main promotion
is authorized for this prerelease. This is a recorded
release exception, not evidence the volume defect is fixed. Record current checks,
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
6. Merge only after the required `Quality Gate` passes on the up-to-date PR/test
   merge candidate, discussions are resolved, scoped P0/P1 findings are closed and
   required physical gates plus owner/authorized merge decision are recorded.
   Merge one PR at a time; do not use bypass/admin overrides or skip failed checks.
7. **Squash-merge focused task PRs** into alpha. Record resulting integrated SHA;
   verify post-merge CI on it before using it as an accepted dependency. PR-head
   tests are not proof of the new integrated commit. If it fails, stop dependent
   integration and submit a focused fix/revert PR; do not push a hidden repair.
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

Desired protection on alpha/main: PR required, required current `Quality Gate`,
up-to-date base, resolved conversations, no force pushes/deletion or routine
bypass. Require eligible independent approvals when available. Until repository
settings enforce these rules, agents must enforce them procedurally and report
that distinction. This file alone does not install branch protection.

Check actual rulesets/protection and required-check names before changing settings.
Do not mark a job required simply because a workflow calls it a gate; do not treat
an advisory failure as success of that advisory. The OS 27 gate is the current
product gate; legacy toolchain advisory status is reported separately. Never
remove tests or make failures optional to merge a change.

## Builds, devices and release provenance

Use per-worktree derived data from `./scripts/build.sh`. The maintainer serializes
Xcode builds and simulator/physical tests. Explicitly select an existing authorized
destination using `VELACANTO_IOS_SIMULATOR_DESTINATION`; a script default may be
stale. Keep only the retained iPhone and iPad simulators; do not create more for
parallel testing. Protect original-reference apps and Foundation106. Physical
**iPhone 17 Pro is excluded** from testing and cleanup. Do not overwrite a reference
or delete archives/unintegrated work to make room for tests.

Local checks include `./scripts/preflight.sh --skip-xcode`, `git diff --check`,
lint and relevant tests/builds. CI must validate PR candidates and integrated
alpha/main commits. Required checks must actually run on relevant changes; do not
leave a required check indefinitely pending through workflow path filters. Scope
verification proportionately for documentation; runtime/interface changes require
relevant regression, platform and physical evidence. Compiler/test success does
not prove streaming, audibility, signed distribution or accessibility.

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

Final handoff: base and final SHA, PR/issue, owned paths, tests/results, privacy
review, pending gates, integration status and next owner. Report local, published,
merged, accepted and distributed as distinct states. Never mark documentation or
implementation Done merely because a local commit or draft PR exists.
