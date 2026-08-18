# Agent assignment prompt

## Save this prompt

> Implement Velacanto issue #`<number>`.

Replace `<number>` with the GitHub issue number. For example:

> Implement Velacanto issue #78.

This is intentionally the complete assignment prompt. An agent working in this
repository automatically receives [`AGENTS.md`](../AGENTS.md), which requires
it to read the GitHub issue contract, verify dependencies and file ownership,
create or use an isolated worktree from current `origin/alpha`, run the stated
checks, commit locally, and return structured handoff evidence.

If the agent does not already have repository context, use:

> Implement Velacanto issue #`<number>` in `schillt/velacanto`. Follow the
> repository's `AGENTS.md` and the complete GitHub issue contract.

Do not paste implementation suggestions into the prompt unless they represent
a deliberate change to the issue contract. Update the issue first when a
missing decision would materially change scope or architecture.

## Integration prompt

After an issue agent returns a commit and evidence, use:

> Review and integrate the completed work for Velacanto issue #`<number>`.

The integration agent independently reviews the diff, applies one accepted
commit to a fresh worktree based on latest `origin/alpha`, reruns the required
checks, pushes only to `alpha`, waits for the hosted Quality Gate, and then
updates GitHub tracking.
