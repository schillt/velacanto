# Velacanto agent guide

## Current product and release

Velacanto 0.3.0 replaces the old app with the build 106 native rebuild. There is
one maintained application: NativeFoundation/VelacantoFoundation.xcodeproj,
scheme VelacantoFoundation, product Velacanto. Read NativeFoundation/AGENTS.md,
ADR 0012, ADR 0013 and docs/0.3-release-notes.md. Root scripts target this rebuilt
product. Do not reintroduce removed legacy code or tests from historical plans.
The owner approved one source-snapshot squash onto alpha, original production
bundle identity, fresh sign-in, GitHub prerelease and internal TestFlight.
Beta/preview/main stay unchanged. Later cleanup must preserve release evidence.

Every worker must proactively hand off its exact base and final commit, owned
paths, verification results, privacy audit, limitations and integration guidance.
The coordinator serializes integration and device builds. Read the active app
contract before applying historical network or milestone instructions.

## GitHub is the source of truth

The GitHub repository, its integrated commits, issues and latest relevant issue
comments are authoritative for shared implementation and task contracts. Use the
Project and milestones for delivery status; resolve any disagreement against the
issue contract and exact integrated commit before marking work complete. For
current development, fetch `origin/alpha` and read its AGENTS.md plus the applicable
app contract before assigning or starting work. `main` represents promoted release
history, not automatically the current development instructions.

Local worktrees, private notes, chat summaries and unpushed planning documents are
working material until published through the approved integration workflow. Do
not treat them as integrated dependencies or silently replace GitHub contracts
with stale local copies. Explicit current owner instructions can change scope;
record the resulting approved contract in GitHub through the coordinator so other
workers receive the same instructions. Preserve existing issue history and never
publish credentials or private device/server evidence.

## Subagents and parallel work

The owner authorizes subagents for delegation. The coordinating agent may assign
multiple independent, bounded tasks at the same time without asking for permission
for each subagent. Delegate when it enables useful parallel progress; simple work
can remain with one agent. Delegation does not expand the authorized task scope.

- Give each worker the GitHub issue or bounded subtask, exact base SHA, owned paths,
  dependencies, acceptance criteria, privacy constraints and expected handoff.
- Independent implementation issues use separate worktrees and local-only branches.
  Read-only research/review can run alongside implementation. Workers sharing an
  issue must have non-overlapping write ownership; never edit the same file
  concurrently. The coordinator resolves ownership conflicts before work starts.
- Do not start dependent implementation on unintegrated assumptions. Wait for its
  accepted dependency on GitHub, refresh the base, then assign the next stage.
- Workers run focused checks and return their exact commit, changed paths, results,
  limitations and unresolved P0–P3 findings. A subagent's completion is a handoff,
  not proof of integration, physical acceptance or release readiness.
- The coordinator reviews results, reconciles findings and integrates one change
  at a time. Only the coordinator publishes accepted work and updates GitHub
  delivery status through the existing integration workflow. Issue workers do
  not push, merge, or independently change issues/Project fields.
- Serialize Xcode builds and simulator/physical-device tests through the
  coordinator. Use the existing retained iPhone and iPad simulators; do not create
  extra simulators to parallelize tests or overwrite protected reference apps.
  The physical iPhone 17 Pro remains excluded from testing and cleanup.
- Preserve other workers' uncommitted/unintegrated work. No reset, stash, revert,
  branch deletion or artifact cleanup to resolve contention. Report the conflict
  and continue only independently owned work until it is resolved.

## Assign an issue

The canonical assignment prompt is:

> Implement Velacanto issue #`<number>`.

That one sentence is sufficient. The assigned agent must discover the rest of
the contract instead of asking the project owner to repeat it:

1. Read this entire `AGENTS.md` before acting.
2. Read the complete GitHub issue, including its latest relevant comments.
3. Confirm the issue's dependencies are integrated into `origin/alpha` and its
   owned files do not conflict with another active worktree.
4. Create or use exactly one isolated local worktree for that issue, based on
   current `origin/alpha`.
5. Implement only the issue contract, run its verification, commit locally,
   and return the required handoff evidence.

If a dependency is incomplete, the issue contract is missing a material
decision, or the owned files conflict with active work, stop and report the
specific blocker. Do not invent scope or edit another issue's work. Issue
agents do not push, merge, update issues, or change Project fields.

## GitHub access and delivery tracking

Use the authenticated GitHub CLI (`gh`) for repository, issue, milestone, pull
request, and private Project operations. Do not put tokens in commands, files,
issues, pull requests, logs, or documentation.

Before any GitHub write, verify access and repository identity:

```sh
gh auth status
gh repo view --json nameWithOwner --jq .nameWithOwner
```

The authenticated account must have `repo` and `project` scopes for the private
`Velacanto Development` Project. If access is missing, stop and ask the project
owner to authenticate or grant the needed scope; do not work around it with a
personal access token, copied cookie, or unverified API request.

The GitHub app connector is useful for reading, but private Project writes may
not be authorized through its integration. When that happens, use `gh` after
the checks above. Treat a 403 response as an authorization problem, not a
reason to retry blindly.

### Complete and hand off an approved issue

For an assigned, in-scope issue, work only in that issue's local worktree.
Run its local checks, commit the focused changes locally, and hand off the
branch name, commit ID, and verification evidence to the integration agent.
Do not push an issue branch to GitHub and do not create an issue pull request.

```sh
git status -sb
git add <only-the-assigned-files>
git commit -m "<focused issue summary>"
git rev-parse HEAD
```

### Integrate and push `alpha`

Only the integration agent moves accepted local issue commits to the shared
remote. Integrate one issue at a time in a clean local worktree based on the
latest `origin/alpha`, run the required checks, and then push the resulting
candidate directly to `alpha`.

```sh
gh auth status
git fetch origin alpha
integration_worktree=$(mktemp -d /private/tmp/velacanto-integrate-<number>-XXXXXX)
git worktree add -b codex/integrate-<number> "$integration_worktree" origin/alpha
cd "$integration_worktree"
git cherry-pick <accepted-issue-commit>
# Run the issue's required checks here.
git push origin HEAD:refs/heads/alpha
```

`gh auth status` succeeding means GitHub CLI authentication is valid. Do not
report it as invalid because a sandbox requests network permission or because
the GitHub app connector returns `403 Resource not accessible by integration`;
request the approved network permission and use `gh` instead. Report
authentication as invalid only when `gh auth status` itself fails. If the
`alpha` push is rejected after a successful status check, report the exact
remote message and stop rather than changing credentials or retrying blindly.

After the push, remove the clean integration worktree and delete its local
integration branch. Wait for the hosted Quality Gate on that exact `alpha`
commit, then update the issue, Project, and 0.3 umbrella only if it passes.
Promotion from `alpha` remains `alpha → beta → preview → main` with the
documented release gates.

### Worktree isolation

Use one clean local worktree and one local-only branch for exactly one issue.
Never add a second issue to an existing worktree, even if its branch is already
open. Before editing, check `git status --short` and `git worktree list
--porcelain`; if either shows another issue's work, stop and use a new worktree
based on the current `origin/alpha` instead.

```sh
git fetch origin alpha
task_worktree=$(mktemp -d /private/tmp/velacanto-issue-<number>-XXXXXX)
git worktree add -b codex/issue-<number> "$task_worktree" origin/alpha
cd "$task_worktree"
```

Do not reset, stash, revert, commit, stage, or move changes made by another
issue. Hand off the focused commit for serial integration into `alpha`, then
remove its clean worktree and delete its local branch before starting another
issue.

### Xcode and test isolation

Treat the `alpha` worktree as the canonical combined-app test tree. Use it only
for integration and release-candidate testing. Open each issue's own
`NativeFoundation/VelacantoFoundation.xcodeproj` in a separate Xcode window for focused development and
testing; do not build or run another issue from the `alpha` window.

`./scripts/build.sh` gives each worktree a distinct derived-data directory by
default. Do not override `VELACANTO_DERIVED_DATA_PATH` with a shared path. Select
an existing authorized simulator explicitly with
`VELACANTO_IOS_SIMULATOR_DESTINATION`; do not assume a script's default destination
still exists. Keep one iPhone and one iPad simulator and preserve their reference
apps. The coordinator serializes Xcode builds, simulator and physical-device
tests because the app shares bundle identity and device state.

An issue agent proves focused behavior in its own tree. The integration agent
proves combined behavior in a clean `alpha` tree after applying the accepted
commit. Unintegrated worktrees are intentionally not a combined test target.

### Issues, milestones, and board

- Inspect first; preserve issue history and existing Project items.
- Every open issue must have a concrete milestone or an explicit Backlog
  classification. Do not invent milestone dates.
- Create independently actionable issues: Outcome, User behavior,
  Implementation boundaries, Acceptance criteria, Out of scope, Dependencies,
  and Verification.
- Query Project fields and option IDs before changing them; those IDs are
  environment data and must not be guessed or hard-coded from old notes.
- After every issue completion, refresh the 0.3 umbrella checklist and verify
  its Project status by issue number and title. Mark documentation work Done
  only after its pull request is merged.
- Keep 0.3 implementation on `alpha`. Follow the documented promotion path
  `alpha → beta → preview → main`; record exact candidate commits for preview
  and final release acceptance.

Useful read-only checks:

```sh
gh issue list --state open --limit 200 --json number,title,milestone
gh project list --owner "$(gh repo view --json owner --jq .owner.login)"
gh project item-list <number> --owner <owner> --limit 200 --format json
gh pr view <number> --json state,mergeStateStatus,statusCheckRollup
```

Issue agents create focused local commits and hand them to the integration
agent; they do not publish branches or open pull requests. The integration
agent runs `./scripts/preflight.sh --skip-xcode`, `git diff --check`, and the
relevant build/test gate before pushing the accepted commit to `alpha`, then
waits for the hosted Quality Gate on that exact commit. Do not change
application behavior or version/build metadata in a planning-only issue.

### Branch lifetime

GitHub's shared branches are `main`, `alpha`, `beta`, and `preview`. All new
issue and integration branches are local only. A recovery branch explicitly
documented on an issue may remain remote until its disposition is complete,
but do not create another remote issue branch. All 0.3 implementation lands in
`alpha` through the single integration-push workflow above. Before deleting a
local branch, verify its work was integrated and it is not checked out in a
worktree. Never discard unintegrated work to tidy the branch list.

## Product and privacy boundaries

The 0.3 work is provider-neutral catalog/actions, native player surfaces, and
acceptance coverage. Jellyfin connection and account UI remains explicitly
provider-specific. Do not add offline audio, playlist mutation, CarPlay
implementation, provider plug-ins, credentials, server addresses, personal
media names, or full request URLs outside their assigned scope.
