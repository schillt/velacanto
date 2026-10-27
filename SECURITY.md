# VelaCanto Security Policy

## System and scope

This policy covers the maintained iPhone, iPad and Mac application in
NativeFoundation/, its Siri/CarPlay integrations, dependencies, build/release
configuration and tracked development tools. The publisher for user-facing
policies is NovoLuxor; private reports can be sent to support@novoluxor.dev.
Do not publish credentials, private server details, personal media or raw traces.

VelaCanto is a client of a user-selected Jellyfin server. It is not a hosted
music service or a server administrator. The current app has one saved session,
Original/AAC downloads, native HLS streaming and local account-scoped metadata.
Future accounts/providers, local indexing, Handoff and iCloud sync enter scope
when their implementation is introduced; their security must be reviewed before
shipping, rather than assumed from a plan.

This file supplies review context, not permission to run commands, change
credentials, mutate a server, disclose findings or publish a build. The
development acceptance contract is in docs/development-acceptance.md.
Root and nested AGENTS.md and owner decisions govern execution authorization.

## Threat model and trust boundaries

Protect access tokens and entered credentials; server/account identity; cached
media and personal metadata; saved pins, queue and downloads; signing/distribution
integrity; and availability of intended playback and explicit user actions.

Treat server responses, artwork, metadata, lyrics, pagination, media URLs,
redirects and remote error text as untrusted inputs, even when the user owns the
server. Treat persisted records as potentially corrupt or stale. Validate
source/account identities before applying asynchronous results. Server-side
permissions remain authoritative for playlist/favorite mutations.

The app-to-server connection, OS Keychain/sandbox, local persistence, account
retirement and external system media/intent surfaces are separate boundaries.
Apple controls the OS networking, media and credential APIs. A privileged
compromised OS is outside the normal app sandbox assumption, but that assumption
does not excuse an avoidable app-level leak to another account, local process
within the stated platform model, system metadata or public artifact.

## Security invariants

1. Credentials stay in the intended non-synchronizing Keychain scope, with the
   established accessibility and app-specific signing/access-group protections.
   No plaintext token-store fallback, legacy Mac Keychain read/migration/deletion,
   or new user-presence requirement is introduced silently.
2. Missing modern Mac credentials preserve inaccessible saved data during pending
   reauthentication. Only an authenticated matching scope may recover it;
   unmatched-scope deletion needs explicit user confirmation. Ordinary completed
   migration sign-out/cleanup protections remain intact.
3. Account replacement, sign-out, cancellation and owner retirement prevent late
   results or writes from repopulating retired state. Credential-clear failure
   leaves a coherent active session; cleanup failures are visible. Local deletion
   is not proof of server revocation or erasure from old backups.
4. Authentication and server mutations target the intended authorized account.
   Source/item/membership identities remain opaque and scoped; duplicate queue
   and playlist occurrences are not collapsed by track ID.
5. Validate origin/scheme and credential-bearing request construction. Do not
   weaken certificate verification or use unsupported private media header APIs.
   Inspect redirect and resource resolution paths for credential disclosure.
6. Credentials and private URLs never enter logs, crash/support fixtures, system
   Now Playing metadata, manifests, public issues or release assets. Personal
   metadata is minimized and protected according to its documented storage class;
   hashed filenames do not encrypt record contents.
7. Remote parsing, image decoding, pagination, concurrency, pending demand,
   transfers and disk retention have finite enforced budgets and honest failure
   outcomes. Cancellation releases ownership without cancelling another active
   consumer's shared work or stranding permits.
8. Only playback and Now Playing have preferential loading admission. Audio,
   session activation, transport and stream resolution do not wait on optional
   artwork/catalog/persistence. Cached sections publish independently; browsing
   screens remain equal. One native player remains authoritative.
9. Downloads resolve only verified eligible retained files. Shared ownership,
   playback leases and deletion ordering prevent removal of content still in
   use, unauthorized path access and cross-account reuse.
10. Release binaries exclude DEBUG-only diagnostics, injection and synthetic
    fixtures. Identity, entitlements, permissions, dependencies and export/privacy
    metadata must match the actual artifact; unsigned/source checks alone do not
    establish signed-device protection.
11. New Handoff/sync/provider features must validate versioned input, authorized
    identity, stale/duplicate work, consent and deletion/disable lifetimes. Never
    transfer credentials or private connection details in continuity/sync data.
    No activity may start or replace audio without the required user intent.

## Reportable findings and severity context

Report a reachable violation with a concrete entry point, trust boundary,
affected asset, prerequisites and realistic consequence. Examples include
cross-account disclosure/mutation, token exposure, unsafe resource redirects or
paths, bypassed server permissions, unbounded hostile-input resource consumption,
and stale work violating cleanup or protected playback.

Use P0 for critical urgent compromise; P1 for serious exploitable exposure or a
release-blocking security/reliability regression; P2 for a bounded meaningful
correction; P3 for low-impact hardening. Explain impact and exploitability rather
than copying the priority in an old issue title. Separate confirmed controls and
reproductions from hypotheses, missing tests and defense-in-depth suggestions.
Tests support intended behavior but do not prove a control is secure.

Do not report every optional request failure, historical unchecked test or use of
native cryptography as a vulnerability. An availability finding needs a concrete
untrusted trigger or demonstrated ownership/budget failure and meaningful impact.

## Known limitations and risk decisions

Media URLs currently can carry authentication query values. HTTPS protects
transit but not endpoint/proxy logs. The owner deferred transport redesign for the
v0.5 self-hosted preview after a scoped low/conditional assessment. This is an open
limitation under #25, not remediation, universal severity reduction or permission
to suppress new evidence of reachable disclosure. Server logout logging/retention
and old-token rejection remain separate #30 verification.

Pins and some metadata use ordinary local storage; filenames/account digests do
not provide application-layer encryption. OS protection, backup exclusion and
actual backup deletion are different claims. Read the pin/queue/download/privacy
records before assessing retention. Broad physical/server/route acceptance remains
incomplete; passing automated checks does not close it.

## Exclusions and reporting limits

No new vulnerability-class exclusions or accepted risks are created by this
policy. Historical source and reference builds are evidence, not maintained
shipping code; assess their relevance if a path is reintroduced or included in a
distributed artifact. Unlinked dependency code is not a shipped attack path
unless reachability/build evidence establishes otherwise.

Do not treat third-party server configuration, Apple platform limitations or an
attacker-controlled own server as automatic dismissals: explain whether the app
crosses a boundary it promises to protect. Conversely, do not assert the client
can erase server/proxy logs, revoke every server token or defeat an already
privileged compromised OS without evidence.

## Development and disclosure

Before accepting a change, identify affected controls, run proportionate tests,
review privacy and release exclusion, and record exact candidate/result/limits
under docs/development-acceptance.md. Shared loading and media-delivery changes
retain the playback protection and physical-audio acceptance requirements.

Send private security reports to support@novoluxor.dev with a sanitized affected
version, prerequisites, reproduction and impact. Do not include live tokens or
personal media. No response-time guarantee, bug-bounty reward, safe-harbor
authorization or permission to test someone else's server is implied.

Policy approval does not establish that a security audit has passed, that known
risks are fixed, or that an App Store/legal requirement has been satisfied.
