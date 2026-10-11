# Velacanto agent guide

## Authority and current product

GitHub `schillt/velacanto` is the shared source of truth: integrated source,
versioned project instructions, issues and their latest relevant comments.
Projects and milestones track delivery status; they do not override the issue
contract or prove integration. Fetch `origin/alpha` before starting current
implementation. Local notes, chat summaries and unpublished plans are working
material, not integrated dependencies. Record approved changes in GitHub through
the workspace maintainer so every worker receives the same contract.

The owner-approved workflow, updated 2026-10-10, keeps development branches and
worktrees local. Publish accepted changes to `alpha`; promote candidates through
an **alpha → beta PR**. A local `codex/` branch name is an implementation detail,
not a reason to create a GitHub development branch. Main/release distribution
requires its own authorization and acceptance. See [workflow](docs/development-workflow.md).
This supersedes the earlier requirement to publish every task branch and open a
PR into alpha. Preserve existing branches and historical PR evidence; do not
force-push, rewrite history or delete unintegrated work during this transition.

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
- **Workspace maintainer:** maintains project/setup/docs, publishes accepted local
  integration to alpha, coordinates promotion PRs and build/device slots, and
  executes authorized promotion merges.
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

## Local development, alpha publication and promotion

The normal flow is **issue → local task branch/worktree → accepted local
integration → alpha publication → alpha → beta PR**. Beta is the validation
stage. Promotion from beta into main and tagged distribution needs a separate
owner-authorized release decision; preview is not a mandatory stage.

1. Read the assigned issue and latest relevant comments. Record outcome, user
   behavior, boundaries, acceptance, dependencies, verification and P0–P3 priority.
2. Fetch alpha. Confirm dependencies and worktree ownership. Start one clean,
   isolated local branch/worktree per issue from current `origin/alpha`; record
   its full base SHA. Never reuse another worker's dirty tree. Do not publish
   temporary task branches unless the owner explicitly requests a remote review.
3. Implement the issue contract and commit only explicit owned paths. Run focused
   checks and `git diff --check`; preserve others' dirty work and references.
4. Acceptance and audit review the exact local candidate. Resolve discussions and
   scoped P0/P1 findings, and complete relevant physical checks or record an
   owner-approved pending gate. A task assignment alone is not acceptance or
   permission to publish unreviewed work.
5. The maintainer integrates accepted local commits serially from current alpha.
   If alpha advanced, integrate its changes locally and rerun affected checks.
   Review the complete publication diff and sanitized issue evidence before writing.
6. Publish accepted integration to alpha with a normal fast-forward push or the
   GitHub connector's non-force ref update guarded by the expected old SHA. Never
   force-push or bypass actual protection. If a rule blocks publication, report
   the rule; do not weaken settings or create a remote task branch as a workaround.
7. Verify the published source/tree and record its integrated SHA, local evidence
   and remaining gates in the issue or development record. Do not publish local
   signed apps, private evidence, credentials or raw traces.
8. Freeze an owner-selected alpha candidate. Run the required hosted release gate
   on its exact SHA, then open/merge **alpha → beta** with a merge commit after
   success and the owner-authorized promotion decision. Recheck head/base before
   merging. If alpha changes, freeze and validate the new candidate rather than
   silently promoting untested changes. No separate remote candidate branch is
   required. Use immutable candidate tags when tagging is authorized.
9. Update issues/milestones after integration and actual acceptance. Keep
   implementation, accepted behavior and distribution separate. Remove local
   task worktrees only after proving integration and preserving needed evidence.

Do not squash long-lived promotion branches or rebase/force-push shared branches.
Retain existing beta/preview/recovery branches until explicitly retired. Independent
agent review is useful evidence, not an approving review from another GitHub account.

## GitHub access and enforcement

Before a GitHub write verify the authenticated account, intended repository and
write permission using the available interface. The authenticated GitHub plugin
is an approved interface for repository/issues/PRs and supported Git data writes.
Authenticated `gh` or Git may also be used when already available; CLI sign-in is
not a prerequisite when the plugin can perform the task. Use an authenticated
browser only for capabilities the connector does not expose, such as workflow
manual dispatch. Never extract or copy tokens/cookies between interfaces.

Private Project work requires appropriate access; query field/option IDs rather
than copying stale values. Stop on actual missing authorization or a rejected
write. Diagnose sandbox/network failures through the normal permission mechanism
before asking for reauthentication. Do not change credentials, bypass protection
or retry a rejected write blindly.

Desired alpha policy permits the maintainer's accepted non-force publication,
with no force pushes/deletion or routine bypass. Beta/main promotions use PRs,
resolved discussions and the applicable exact-candidate hosted gate. Require
eligible independent approvals when configured; never impersonate a reviewer.
Until settings enforce a rule, agents enforce it procedurally and report that
distinction. Documentation does not install or change GitHub protection.

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
lint and relevant tests/builds. Ordinary patches, documentation changes
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

Open a release PR from beta into main after full candidate acceptance and a
separate owner-authorized main promotion decision. Verify its final integrated
source and checks, retain the candidate-to-release mapping,
and tag the accepted release. Build signed artifacts from recorded source and
verify distribution separately; an unsigned CI build is not a TestFlight build.
Keep alpha frozen through release promotion or use a separately approved release
branch strategy if continued development is necessary. Hotfixes use a focused PR
from current main, then reconcile the accepted fix locally and publish it to alpha
before further release promotion. No routine cherry-pick-only divergence between
shared branches.

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
