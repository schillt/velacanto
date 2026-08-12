# Velacanto agent guide

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
integration branch. Promotion from `alpha` remains `alpha → beta → preview →
main` with the documented release gates.

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
`Velacanto.xcodeproj` in a separate Xcode window for focused development and
testing; do not build or run another issue from the `alpha` window.

`./scripts/build.sh` gives each worktree a distinct derived-data directory by
default. Do not override `VELACANTO_DERIVED_DATA_PATH` with a shared path. When
two issue trees need simulator testing at the same time, give each a distinct
simulator destination with `VELACANTO_IOS_SIMULATOR_DESTINATION`; otherwise run
simulator and physical-device tests serially because the app shares a bundle
identifier and device state.

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

Use focused commits, push a `codex/`-prefixed branch, open a PR against the
agreed base branch, and wait for required hosted checks before merge. Run
`./scripts/preflight.sh --skip-xcode`, `git diff --check`, and the relevant
build/test gate before publishing. Do not change application behavior or
version/build metadata in a planning-only issue.

### Branch lifetime

GitHub has exactly four branches: `main`, `alpha`, `beta`, and `preview`.
All issue and integration branches are local only. All 0.3 implementation lands
in `alpha` through the single integration-push workflow above; never create or
push an issue branch to GitHub. Before deleting a local branch, verify its work
was integrated and it is not checked out in a worktree. Never discard
unintegrated work to tidy the branch list.

## Product and privacy boundaries

The 0.3 work is provider-neutral catalog/actions, native player surfaces, and
acceptance coverage. Jellyfin connection and account UI remains explicitly
provider-specific. Do not add offline audio, playlist mutation, CarPlay
implementation, provider plug-ins, credentials, server addresses, personal
media names, or full request URLs outside their assigned scope.
