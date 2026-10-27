# Optional iCloud pins — issue #198 development candidate

Live issue and all comments checked 2026-10-26: issue #198 remains open with no
comments. Base is local integration `7f1e028`; remote alpha is a separate lineage.
This is source implementation for review, not feature acceptance. No container,
capability, provisioning profile or CloudKit schema has been created or changed.
No installation, upload, distribution or publication occurred.

## Native behavior and ownership

Pins still use the existing account-owned `FoundationLibraryActions` writer.
Its native item menus expose Move Pin Earlier/Later on both platforms, including
when sync is off. Each successful local pin mutation is saved before optional
sync begins. Settings includes the native default-OFF sync control. With no
`VelacantoPinSyncContainerIdentifier` configuration, it is disabled and explains
that this build cannot sync; the CloudKit container is never constructed.

A configured, explicitly enabled account starts a bounded exchange at opt-in,
account-owner startup, foreground activation, local pin changes or Sync Now.
There are no timers, automatic error retries, subscriptions or background scans.
A remote edit is observed at the next such exchange, rather than immediately
pushed to an idle foreground device. An exchange makes at most two
compare-and-save attempts. Audio and visible browsing never await it.

The native adapter uses only the named container's private database. One
`VelaCantoPinsV1` record per existing SHA-256 server/account scope has a `payload`
Bytes field. Payload version 1 contains scope digest, cloud-reset epoch, opaque
pin ID/kind, order, logical stamps and removal contexts. It contains no title,
subtitle, credentials, connection URL, artwork, path or downloaded media. Hashes
are identifiers, not encryption or anonymity guarantees. References resolve only
through the current authorized account's `itemDetails`; missing items are omitted
locally and retained in the sync state. Metadata resolution is serial, bounded
by the record's pin count, cancellable and guarded again before persistence.

## Merge, deletion and retention

Initial opt-in adds only previously unseen local identities to cloud membership;
cloud tombstones suppress stale snapshots. Concurrent independent additions are
retained. Ordering uses a logical clock and stable per-installation random UUID
as a deterministic tie-breaker; pins absent from the winning order append in
identity order. Membership is remove-wins: each pin retains up to 32 device
removal counters, and an explicit re-add must have observed every known removal.
A higher unrelated clock or a concurrent remove/re-add cannot revive a deleted
pin. Only a deliberate later pin operation after reconciliation can re-add it.

There is a hard limit of 2,048 entries including tombstones and 512,000 encoded
bytes. No unsafe tombstone expiration occurs. Hitting a budget stops sync with an
honest failure while preserving the local pins; a separate explicit cloud reset
is available, rather than silently dropping removals. CloudKit compare-and-save
prevents overwriting a concurrently advanced server revision.

Turning sync off cancels ownership and stops new cloud operations; local pins and
cloud data are retained. Already-submitted native requests cannot be recalled,
but late responses cannot apply to local state. Local edits are journaled for a
later explicit re-enable without cloud traffic. An iCloud account-change
notification disables sync, cancels old work and clears the old cloud association;
explicit opt-in is needed for the new account. Persisted account fingerprints
also reject a mismatched iCloud account even if no notification was observed.

Delete Cloud-Saved Pins requires a separate native confirmation. It replaces the
cloud payload with a fresh empty epoch, keeping this device's visible local pins.
Other enabled devices adopt that epoch on their next exchange; old offline edits
are discarded rather than migrated. A reset sentinel remains in CloudKit so an
old device cannot recreate the erased generation. This does not claim erasure
from Apple's historical backups or storage history. Later *new explicit local*
pin changes may sync again; merely keeping old local pins does not upload them.

The journal contains minimal identities, tombstones, order, random installation
identity, hashed cloud-account association and scoped consent in ordinary local
UserDefaults. It is not application-encrypted and may enter device backups.
Successful credential deletion retires the sync owner before local pin/journal
cleanup. Failed credential deletion retains the active pin owner. Sign-out removes
all local sync journal scopes and never deletes cloud pins implicitly. Account
replacement retains only the authorized scope under existing cleanup policy.

## Concrete capability review gate (not applied)

The existing project uses team `B9X8T5LT8Q`, canonical app identifier
`com.chameleonenterprise.velacanto`, and preserved local Alpha identity overrides.
The exact proposed container name for owner review is
`iCloud.com.chameleonenterprise.velacanto`; this is a **proposal**, not evidence
that Apple has registered it. Use the same reviewed container on iPhone/iPad/Mac.
After owner approval and Apple-side verification, the proposed source shape is:

```xml
<!-- Both app entitlements, preserving existing unrelated keys: -->
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.com.chameleonenterprise.velacanto</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudKit</string></array>
<!-- Both platform app Info.plists, only after capability/profile verification: -->
<key>VelacantoPinSyncContainerIdentifier</key>
<string>iCloud.com.chameleonenterprise.velacanto</string>
```

No ubiquitous key-value store, iCloud Documents or Intents-extension access is
requested. Xcode-managed environment/container-development entitlements must
match the real development or distribution profile; do not hard-code a false
production environment. Verify app-ID/container association and actual embedded
profiles/signed entitlements separately for canonical and retained Alpha Mac
identities. Keep existing modern Keychain groups stable. Define the private
`VelaCantoPinsV1.payload` Bytes schema and explicitly review production schema
deployment separately. No public/shared database or account login is authorized.
A configured Info.plist alone does not prove capability availability.

## Verification and remaining gates

Nine pure-state semantic test bodies passed in an isolated Foundation-only Swift
harness with assertions, including concurrent remove/re-add versus removal. This
is not a native XCTest or signed CloudKit result. Isolated pure-state warning-free
typechecking passed before the final removal-vector refinement; final semantic
harness recompilation passed. Standalone XCTest/SwiftPM attempts were unavailable
under local sandbox/module setup; no app test result is inferred from them.

Canonical `FoundationPinSyncStateTests` (9 cases) and
`FoundationPinSyncLifecycleTests` (7 cases) are supplied for the serialized native
lane. They cover migration, ordering, causal deletions, epoch reset, scope/budget/
payload checks, late callbacks, disable during metadata resolution, default OFF,
local ordering, scoped journal cleanup and failed credential clear. Project file
inclusion and native iOS/macOS builds/tests remain the maintainer's next gate.
The private CloudKit adapter still needs native compilation and conflict/account/
offline acceptance against disposable authorized accounts.

Before #198 can close: independent source/privacy review; native regression and
Release checks; approved capability/profile/schema setup; signed iPhone/iPad/Mac
acceptance of matching-scope convergence, initial merge, concurrent/offline edits,
ordering, removal, disable/re-enable, missing media, cloud erase with an old offline
device, iCloud sign-out/account switch and Velacanto sign-out. Name the exact
candidate and audible/browsing sanity evidence separately. The v1 checklist must
record accepted feature evidence. This source candidate does not clear release
milestone disposition or authorize shipping the disabled feature as complete.

Apple API reference: [private-record compare-and-save](https://developer.apple.com/documentation/cloudkit/ckdatabase/modifyrecords(saving:deleting:savepolicy:atomically:)).

## Independent-review corrections — 2026-10-26

The first source review identified three P2 correctness defects in the initial
candidate. The queued native account-change task now captures consent generation
before enqueueing and checks both active lifetime and that generation before any
journal mutation/write. A retired notification cannot recreate cleared local data.

Initial opt-in now preserves a local reorder performed during the held initial
exchange while retaining remote-only pins and honoring cloud removals. It records
that ordering in the journal and follows with the bounded normal exchange.

If a successful local edit cannot fit the sync journal's unchanged entry/device/
byte budgets, a durable `needsRecovery` marker pauses sync. Re-enable, foreground
exchange and relaunch cannot apply remote state over the unjournaled local pins.
Local use stays available. Undoing the unsynced changes until the journal fits
clears the marker; enabling then requires another explicit choice. Merely toggling
sync or changing iCloud account does not clear this protection.

Three additional canonical lifecycle regressions cover the queued-retirement
notification, held initial reorder plus remote-only pin, and capacity pause with
re-enable/relaunch/explicit local recovery. Lifecycle suite is now 10 cases;
these additions have source parsing and whitespace checks only. Native execution,
CloudKit service validation and signed device acceptance remain pending.

A second review caught a relaunch recovery gap: rebuilding the comparison baseline
from visible pins could misclassify an unjournaled addition as old local-only data.
The recovery journal now persists the exact pre-failure local baseline. Unrelated
reordering or removing another pin after relaunch cannot clear the outstanding
addition or bypass the unchanged tombstone budget. Only a successfully represented
local intent clears the recovery marker and baseline. A recovery marker without
its baseline stays paused conservatively. The capacity regression now exercises
both unrelated edits and repeated re-enable before actually undoing the extra pin.
This also preserves unresolved remote identities and avoids uploading deliberately
local-only pins retained after explicit cloud deletion merely to clear recovery.
