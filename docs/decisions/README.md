# Architecture decision records

Architecture decision records (ADRs) preserve important technical choices,
their context, and their consequences.

## Index

| ADR | Status | Decision |
| --- | --- | --- |
| [0001](0001-shared-core-native-surfaces.md) | Accepted | Share domain and service code while keeping native platform presentation |
| [0002](0002-platform-baseline-and-surfaces.md) | Superseded | Target iOS 18 and macOS 15 with native 0.1.0 surfaces |
| [0003](0003-local-http-policy.md) | Accepted | Permit plain HTTP only for local Jellyfin destinations |
| [0004](0004-source-adapters-and-local-file-playback.md) | Accepted | Share one player across source adapters and open local files in place |
| [0005](0005-sideload-only-for-0-x.md) | Accepted | Sideload 0.x builds and defer paid Apple distribution to 1.0 |
| [0006](0006-non-production-jellyfin-validation.md) | Accepted | Isolate non-production Jellyfin validation from personal media and production data |
| [0007](0007-platform-26-baseline.md) | Accepted | Require iOS/iPadOS 26 and macOS 26 for 0.3 and later development |
| [0008](0008-provider-neutral-catalog-actions.md) | Accepted | Keep catalog items, capabilities, and mutations provider-neutral |

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
