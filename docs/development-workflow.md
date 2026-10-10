# Development and promotion workflow

Owner-approved 2026-10-10. [AGENTS.md](../AGENTS.md) is the detailed operational guide.

Develop and test in isolated local branches/worktrees. Temporary development
branches stay local; their names do not create a GitHub publication requirement.
Independent acceptance and audit identify the exact candidate, relevant passing
checks, resolved findings and any owner-approved pending device/server gates.

The maintainer integrates accepted work serially against current alpha, reviews
the exact public diff, and publishes it to alpha with a non-force fast-forward
push or an expected-SHA-guarded connector update. Verify the published tree and
record source, evidence and remaining acceptance in the issue/development record.
Actual GitHub protection still applies; never bypass it or change settings merely
to make a publication succeed.

For an owner-authorized beta promotion, freeze alpha and run the hosted release
quality gate on that exact SHA. Open an alpha → beta PR and use a merge commit
once the gate passes. Verify alpha has not advanced before merging. No remote
local-development or candidate branch is required. Preserve ancestry and use
immutable tags when the owner authorizes tagging.

Main promotion and signed/TestFlight/App Store distribution remain separate
release decisions. Beta → main uses a release PR after full applicable acceptance;
no mandatory preview stage is introduced. Do not move published tags or rewrite
shared branches. Existing branches and historical PRs remain evidence until an
explicit cleanup decision.

Use the authenticated GitHub plugin for supported operations. Use already
available Git/CLI authentication or the authenticated browser when needed; do not
ask for CLI login when the plugin can complete the requested operation.

This workflow does not waive source/publication review, tests, physical gates,
known-issue disclosure or owner release authorization. It changes where routine
development lives and how accepted changes reach alpha.
