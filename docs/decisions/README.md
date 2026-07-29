# Architecture decision records

Architecture decision records (ADRs) preserve important technical choices,
their context, and their consequences.

## Index

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](0001-shared-core-native-surfaces.md) | Accepted | Share domain and service code while keeping native platform presentation |

## Adding a decision

Create the next numbered Markdown file using this structure:

```text
# NNNN — Decision title

- Status: Proposed
- Date: YYYY-MM-DD

## Context

What problem or constraint requires a durable choice?

## Decision

What will the project do?

## Consequences

What becomes easier, harder, required, or intentionally deferred?
```

Use `Proposed`, `Accepted`, `Superseded`, or `Rejected` as the status. If a
later ADR replaces an earlier decision, link both records.

Do not use ADRs for temporary task status, credentials, server addresses, or
other confidential information.
