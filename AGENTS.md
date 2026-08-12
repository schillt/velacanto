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

### Push an approved issue

For an assigned, in-scope issue, agents are authorized to commit focused work,
push its short-lived branch, and open a pull request to `alpha` after the
required local checks pass. Do not ask the user to repeat how to push.

```sh
gh auth status
git status -sb
git push --set-upstream origin "$(git branch --show-current)"
gh pr create --base alpha --head "$(git branch --show-current)"
```

`gh auth status` succeeding means GitHub CLI authentication is valid. Do not
report it as invalid because a sandbox requests network permission or because
the GitHub app connector returns `403 Resource not accessible by integration`;
request the approved network permission and use `gh` instead. Report
authentication as invalid only when `gh auth status` itself fails. If `git
push` is rejected after a successful status check, report the exact remote
message and stop rather than changing credentials or retrying blindly.

Merge only after required hosted checks pass and the assigned task includes the
merge or release promotion. Delete the short-lived source branch after merge.

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

The only persistent remote branches are `main`, `alpha`, `beta`, and `preview`.
All 0.3 implementation lands in `alpha` first. Use a short-lived `codex/`
branch only while its focused PR is active, then delete its remote and local
branches after the PR merges. Before deletion, verify the branch is merged and
is not checked out in a worktree. If it contains unmerged work, integrate it
through its intended PR or ask the project owner; never discard it to tidy the
branch list.

## Product and privacy boundaries

The 0.3 work is provider-neutral catalog/actions, native player surfaces, and
acceptance coverage. Jellyfin connection and account UI remains explicitly
provider-specific. Do not add offline audio, playlist mutation, CarPlay
implementation, provider plug-ins, credentials, server addresses, personal
media names, or full request URLs outside their assigned scope.
