# Modern Mac credential storage

> Historical development record. Candidate-stage status below describes that
> checkpoint, not current availability. The 0.5.0 integration includes the accepted
> HLS, quality/download and modern Mac credential work; see the authoritative
> [0.5.0 acceptance and release record](0.5.0-acceptance.md) for current scope,
> superseding evidence and pending publication/TestFlight gates. Earlier DEBUG-only
> restrictions and “not installed” statements must not be read as current policy.

Integration base: download212 candidate `db0ce646a3dd501178ea9641d67f424071f2e4e8`
in `download-quality-212/`. The modern-Keychain work originated independently on
209 (`578256ebb9189a7058c6e066015a54cbae67ff4e`) and is now reconciled onto the
212 quality/UI source without conflicts. This preserves the 211 Mac-Original
policy, iOS-only system quality selectors, reviewed download pipeline and album-card
UI. It does not itself change playback, quality selection, version metadata, or
the iOS credential backend. The retained 212 number identifies the base, not a
newly assigned Keychain build or an installed Keychain candidate.

Source preparation only: no Xcode, provisioning, signing, probe launch or install
has run for this integration. Final 212 corrections must be reconciled before a
new review/freeze/version is assigned. Quality acceptance does not establish
modern-Keychain readiness; the signed profile/runtime probe gates below remain.

## Owner decision and behavior

Use only the Data Protection Keychain on macOS. All credential load, update,
insert and delete requests explicitly select it. An empty store means signed out;
there is no legacy lookup, fallback, migration, or deletion. Existing legacy items
are left untouched. A one-time fresh sign-in is expected on the first modern-store
build. Keep device-only AfterFirstUnlock accessibility, no synchronization, and no
user-presence/biometric requirement. Locked or unavailable secure storage remains
an honest error rather than triggering weaker storage or a legacy access prompt.

## Signing dependency: not validated yet

The Mac entitlement template uses `$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`
for both its application identifier and its single default Keychain access group.
The existing Automatic signing and `VELACANTO_APP_BUNDLE_IDENTIFIER` path determine
the actual app identity; no hard-coded shared canonical group is introduced.
Canonical and retained local Alpha identities therefore have separate stores.
Do not change their identifiers to make a credential test pass.

Read-only inspection of existing local profiles found two iOS profiles and no
macOS profile. Installed209 Mac has sandbox and network entitlements, but no app
identifier or Keychain access group. A signed build must establish appropriate Mac
provisioning for each identity before this feature can ship. The entitlement
source alone is not proof that a running process has authorized access. Xcode's
automatic signing/provisioning must resolve the app prefix and authorize the
application identifier/access group for canonical and local Alpha builds. If this
requires developer-account configuration, report the precise signing diagnostic;
do not strip required entitlements, re-sign ad hoc, or fall back to legacy storage.
No developer-account mutation has been performed for this candidate.

## Validation gate (serialized build lane)

1. Run FoundationCredentialsTests on Mac and iOS: these use synthetic operations
   and never read or write real sign-ins. Confirm all production requests select
   the proper backend, preserve protections, and never retry against legacy on
   missing items, authorization denial, locked storage, or missing entitlements.
2. Build canonical and retained local Alpha with Automatic signing. Inspect the
   final signature and embedded provisioning profile: valid resolved app prefix,
   exact bundle-derived app identifier, one matching access group, Mac platform,
   valid expiry and profile authorization. Keep strict signature checks.
3. In a separately signed disposable harness under those same entitlements, use a
   unique `Velacanto.Keychain.Validation.<UUID>` service and random synthetic data.
   Use Data Protection selection on every request. Add/read/update/delete only
   that disposable item, cleaning it on success or failure. Never query the real
   `Velacanto.NativeFoundation.Session` service or dump Keychain entries.
4. Repeat disposable-item read after relaunch and a signed binary update retaining
   the same team, app identifier and group. Verify the other identity cannot read
   the item. Verify empty modern storage presents sign-in without accessing legacy.
5. Only after source review and signed validation, integrate in a separate build.
   Preserve prior signed apps/data. Verify owner sign-in/relaunch/update behavior;
   do not describe synthetic tests as proof that every OS prompt is impossible.

The narrow Security-operation seam supports the synthetic tests; production
continues to use SecItem APIs. No passwords, tokens, URLs, item attributes, or
Keychain contents belong in shared diagnostics. The old build can retain its old
store if rolled back; this candidate deliberately does not alter that store.

Apple references:
- https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain
- https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps

## Guarded runner and final integration

`scripts/validate-modern-keychain.py` prepares one serial phase at a time and is
**dry-run by default**. It pins an explicit clean source SHA, the retained simulator,
absolute build/package/evidence directories and the existing Xcode project/scheme.
The `tests` phase selects startup and synthetic credential suites on Mac then iOS;
its unsigned Mac pass cannot establish Keychain entitlement readiness. The `signed`
phase builds canonical then retained local Alpha with Automatic signing, requires
strict signatures, a resolved app-specific default group and an unexpired Mac
profile authorizing both application identifier and group. It stages signed apps
under `/private/tmp` and preserves ZIP/hash evidence without installing/launching.

Do not execute until the root agent grants the serialized lane. Execution requires
`--execute` and `VELACANTO_BUILD_LANE_OWNER=mac-keychain-modern`. External profile
creation/update additionally requires root authorization, the explicit
`--allow-provisioning` flag and
`VELACANTO_KEYCHAIN_PROVISIONING_AUTHORIZED=YES`. Without those gates, a missing
profile is a signing blocker, not permission to weaken the credential backend.
These environment gates document coordination; they are not a security boundary.

The candidate is reconciled onto the frozen212 quality/UI source above. Any
subsequent 212 fixes must first be reconciled, reviewed and frozen again. Supply that exact integrated
SHA to `--expected-source`; do not ship the historical209 base or assign a version
from this preparation work. Ordinary release checks, focused signed disposable
runtime probes and owner acceptance remain separate from the runner's output.

Disposable probe must be a separately packaged, signed app-like harness under each
artifact's **exact identity, entitlement set and matching embedded profile**, run
in the normal logged-in user context. Use one new UUID service and synthetic data,
never the production session service. Capture only statuses/success booleans. The
probe should write and exit, then read in a new process; rebuild/re-sign a changed
probe binary with the same identity and repeat the read, update and delete. A probe
under the other identity should receive item-not-found. Clean up the original
identity's exact UUID item in a finally/cleanup step even if validation fails.
Do not embed or launch the normal app to perform this probe, because startup may
restore real credentials. Do not use `security find-*`, export/dump real items,
modify login Keychain ACLs, or approve legacy prompts. A probe failure blocks
shipping and must retain its status category without secrets.

## Disposable probe driver (prepared, not executed)

`scripts/probe-modern-keychain.py` is dry-run by default. It requires explicit
canonical/local Alpha artifact paths and an exact clean source SHA. Execution
requires the serialized build lane plus
`VELACANTO_DISPOSABLE_KEYCHAIN_PROBE_AUTHORIZED=YES`; it never creates/updates
provisioning profiles. Both artifacts must pass resolved entitlement/profile
checks, including signing-certificate authorization. The driver builds two
versions of an isolated app-like harness for each exact identity, copies its
matching profile/entitlements, signs with the artifact's existing certificate,
and checks strict signatures and identical entitlement sets before launch.

The standalone Swift source is outside the app target. It constructs its own
UUID-prefixed validation service and fixed disposable account; neither arguments
nor configuration permit supplying the production service/account. Each operation
explicitly uses the Data Protection backend, device-only accessibility and no
synchronization or user-presence protection. The driver exercises add, fresh-process
read, changed-binary read, update, fresh-process updated read, cross-identity
not-found, then exact-item delete and not-found verification in a finally block.
It retains finite outcomes only, never raw runtime output, item values or nonce.
If cleanup fails, keep the private synthetic config for an authorized exact-item
cleanup; do not search other items or reset a Keychain. Signed bundles and synthetic
config stay under `/private/tmp`; no app installation or normal-app launch occurs.

## Sign-out and historical credentials

Modern sign-out clears only this identity's Data Protection current-session item.
It does not erase a historical legacy item, nor does local deletion revoke a
server token. The legacy item is deliberately left untouched under the owner's
no-legacy-access policy. Existing sign-out handling remains honest: failed local
clear keeps the active account; server sign-out success/failure is reported
separately. Current text says "Signed out here" rather than claiming universal
credential erasure. No metadata reset or broader account cleanup changes are
introduced by this work.

## Safe first-modern-launch quarantine and exact-scope confirmation

The inherited nil-credential startup and pre-authentication sign-in paths remove
local account data. A new, empty Mac backend must not trigger that loss during an
update. AppModel therefore owns one nonsecret defaults marker. Missing/unrecognized
marker means pending; iOS never enters this path. While pending, missing/locked/
unavailable modern credentials leave all account stores quarantined and create no
library, playback, download or cached-content owners. Failed/canceled sign-in does
not perform the usual pre-authentication cleanup. There is no legacy query.

After successful authentication, inspect only opaque scope names in existing pin,
playback, download, library-selection and disposable-cache stores. Mirror their
actual directory identities (download/artwork/pages use a second scope digest).
No retained scopes or an exact verified-scope match may proceed to the existing
retaining-scope cleanup. Unreadable inventories fail closed. If retained data exists
but none matches exactly, do not infer identity from a similar URL or artist data:
keep quarantine and request a native, destructive confirmation. The owner can retry
using the previous server address, or choose “Remove Local Data and Continue.”
Only this actual mismatch displays the choice. No server-library deletion occurs.

AppModel alone holds that authenticated session and a one-use confirmation ticket
bound to account/startup/authentication generations. The view holds only a ticket.
Cancel, native dismissal, disappearance, new attempts and account retirement revoke
the pending authentication. Confirmation rechecks ownership, consumes the ticket,
then prunes; duplicate/stale confirmation cannot prune or publish. Essential cleanup
must succeed before modern credential saving or account publication. Existing
scoped owners protect matching data. Optional foreign-cache cleanup uses retained
cancelable ownership with checks between awaits and existing directory leases; only
successful cleanup in the same epoch marks the backend ready. It never delays audio
behind optional cache work. A saved modern session with a pending marker can retry
this reconciliation after relaunch. Failed cleanup keeps the marker pending.

Once ready, ordinary missing-credential and explicit sign-out cleanup retain their
existing privacy behavior. Local DP deletion does not touch old legacy credentials.
The existing build-epoch policy still invalidates only its two disposable cache
roots before credential restoration; durable downloads, pins, playback snapshots
and library selections are not part of that cache invalidation. This work does not
promise that ephemeral artwork/page bytes survive a build update.

Validation before the safe-upgrade runtime change: synthetic startup/credentials
passed Mac11/iOS20 on `ea11502`; proper canonical/local Alpha Mac profiles and strict
signatures were obtained at `d0f439f`. Disposable probe18 operations then passed with
cleanup confirmed using the script-only `17d2300` correction. Initial inspector
syntax and sandbox-config transport failures were validation-harness defects, not
credential-store failures. These are entitlement/probe evidence only; the expanded
upgrade runtime still requires frozen-source review, new tests/builds and owner
acceptance. No normal213 app was launched or installed during these checks.
