# Local pin storage — issue #179

VelaCanto saves pinned collection snapshots for the signed-in account in local
`UserDefaults`, under `Velacanto.Foundation.Pins.v1.*`. A snapshot includes an item
ID, kind, title, subtitle, duration and artwork tag. The key contains a digest of
the server/account identity; the values are not encrypted. Pinning and unpinning
do not make a Jellyfin request.

## Local sign-out and account boundaries

Successful explicit sign-out removes the authorized account's local pin snapshot
and `Velacanto.Foundation.PinSync.v1.*` sync journal after its admitted work has
retired. Cleanup uses the captured account scope. It does not erase another
account's records merely because that account is not currently open. The signed-out
UI does not expose a former account's pins, and a new account reads its own scope.
The Settings message, “Signing out removes saved pins from this device,” describes
the account being signed out; it does not promise removal of every retained scope,
cloud record or historical backup.

Local pin cleanup does not require Jellyfin to be reachable. A failed server
sign-out can be reported separately from successful local removal. If credential
or scoped cleanup cannot complete, the app reports incomplete cleanup rather than
claiming success. Failed credential deletion preserves the active account and its
pins; interrupted durable cleanup retains its account-bound recovery intent.

Authentication is not permission to discard data in advance. Pins remain while
reauthentication is pending, fails or is cancelled. Missing or unreadable modern
credentials may quarantine retained account data for authenticated recovery.
Same-account recovery preserves that data. An unmatched upgrade requires the
existing explicit confirmation before other retained scopes are discarded.
Ordinary fresh sign-in does not delete other scopes before requesting a token.
These data-preservation boundaries supersede the older blanket purge policy.

## Optional Production iCloud sync

Production pin sync was accepted under #198 on November 2, 2026. It remains an
explicit per-account opt-in, with account isolation and local availability;
normal accepted iCloud delivery lag does not imply a new app defect. The journal
stores pin identities/order, removal contexts, opaque scope/account digests,
a random device identity and consent in ordinary `UserDefaults`, with the same
unencrypted-storage and backup limits as local snapshots.

Signing out or disabling sync retains cloud records. Explicit cloud-pin deletion
is a separate user action with its own cross-device confirmation and reset epoch;
local sign-out does not perform it. Re-enabling sync for the same account can
restore that account's cloud pins. This is distinct from another account seeing
its metadata. Production feature acceptance does not establish every sign-out,
archive/profile or cross-account edge case in #30/#179.

## Backup and evidence limits

[Apple's UserDefaults documentation](https://developer.apple.com/documentation/foundation/userdefaults)
explains that persistent defaults participate in device backups. Local cleanup
changes the current preferences; it cannot erase copies already captured in older
backups or separately exported device data. VelaCanto does not use iCloud key-value
synchronization for pins. Keep personal pin values, raw preference files and
account/server details out of public issue, test and support evidence.
