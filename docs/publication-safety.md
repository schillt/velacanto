# Publication safety

`schillt/velacanto` is public. The private development Project does not protect
linked repository issues, PRs, commits, Actions logs or release downloads.
These preventive #176 rules do not assert a credential leak in 0.3.5.

## Local artifacts and tracked content

Inventory names/categories locally before changing ignore rules; never upload
private file contents or identifying paths as evidence. Current inventory
justifies root-scoped ignores for `.local-baselines/`, `default.profraw`, the
legacy generated CanvasPreview configuration and Info-Debug plist, and legacy
Xcode Cloud workspace metadata. Baseline storage can contain signed apps and
embedded provisioning material; existing archive/IPA/provisioning ignore
rules also remain. Standalone `.app` directories outside ignored storage are not
covered; retain them only in approved local storage. Ignore rules preserve files; they do not delete references.

Keep signed references, exports, signing keys and provisioning material in
approved local storage outside tracked source (or the ignored baseline directory).
Do not invent broad `*.plist`, `*.xcconfig`, `*.json`, certificate or fixture
exclusions. Intentional example configuration such as `Secrets.xcconfig.example`
and `.env.example`, production resources and synthetic test fixtures must remain
trackable and receive content review. No ignore pattern is a secret scanner.

`git ls-files` describes tracked content; `git status --short` shows working
changes/untracked candidates; `git check-ignore -v --no-index -- <path>` explains
pattern matching. The last command can match an already tracked path: it does
not prove that path is absent from the commit. Ignore additions neither untrack
existing files nor repair published history. Do not clean, force-add or discard
local material while performing this review.

## Bounded pre-publication review

1. Confirm the repository, issue scope, exact base and owned worktree. Verify
   GitHub access before any authorized write; publication and merge are separate.
2. Review only the changed paths and intended release assets locally. Include
   filenames, text, archive manifests, embedded configuration and build-log output
   appropriate to those assets; do not dump an entire home directory or raw logs.
3. Stage explicit owned paths (`git add -- <owned-path> ...`). Inspect
   `git diff --cached --name-status`, the complete `git diff --cached`, and
   `git diff --cached --check` before committing. Stop if unexpected paths appear.
   Never use broad staging or `git add -f` to bypass the artifact boundary.
4. Check positive ignore cases and negative source/example/fixture cases. Review
   the candidate-to-base diff and intended upload list again before publication;
   a clean status alone is not a release privacy check.
5. Preview the exact issue/PR/release body locally before posting. Publish only
   sanitized categories/counts, exact candidate SHAs, relevant relative source
   paths and check results. Exclude secrets, private origins/full request URLs,
   personal media, stable device/account IDs, raw traces and unnecessary home
   paths. Keep detailed evidence local; never paste a suspicious value to prove
   it was found. State the reviewed scope and unresolved limits, not blanket
   claims that all historical content or every artifact is safe.

## If an earlier post exposed information

Editing visible text is insufficient: readers can inspect prior revisions.
With the required authorization, use the comment's **edited → revision → Options
→ Delete revision from history** workflow for affected revisions. Alternatively,
post a sanitized replacement and remove the old comment when authorized and
appropriate; verify the original body/history is no longer publicly visible.
Retain sanitized incident context without reproducing the value. Deletion does
not retract copies, notifications or caches; escalate unresolved exposure to the
owner/GitHub Support. Credential revocation, repository-history rewriting and
artifact deletion require a separately scoped response and are not this issue.

GitHub documents revision visibility and who can remove sensitive revisions in
[Tracking changes in a comment](https://docs.github.com/en/communities/moderating-comments-and-conversations/tracking-changes-in-a-comment).
