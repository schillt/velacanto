# Local pin storage — issue #179

Velacanto Foundation saves pinned collection snapshots for the signed-in account
in local `UserDefaults`. A snapshot includes an item ID, kind, title, subtitle,
duration, and artwork tag. The key contains only a digest of the server/account
identity; the values are not encrypted. Pinning and unpinning make no Jellyfin
request.

Successful local sign-out removes every stored `Velacanto.Foundation.Pins.v1.*`
key, including keys left by older sign-outs for other accounts. A new sign-in
removes those keys before requesting a server token. On relaunch with a saved
sign-in, the app keeps only that account's pins and removes older scopes.
Without a usable saved sign-in, it removes all scoped pins. If removal cannot
be confirmed, the app reports that result. If Keychain removal fails, the
account stays active and its pins remain. Pin cleanup does not depend on
Jellyfin being reachable.

[Apple says](https://developer.apple.com/documentation/foundation/userdefaults?changes=_3&language=objc)
persistent defaults are included in device backups. This cleanup affects the
current app preferences; it does not erase copies already captured in older
backups or in separately exported device data. The app does not use iCloud
key-value synchronization for pins. Avoid putting personal pin values or raw
preference files in issue, test, or support evidence.

## Optional iCloud development candidate — #198

The source candidate adds an account-scoped local sync journal under
`Velacanto.Foundation.PinSync.v1.*`, containing only pin identities/order,
removal contexts, opaque scope/account digests, random device identity and consent.
It uses ordinary UserDefaults with the same backup/encryption limits above.
Successful local cleanup removes these journal keys as well as pin snapshots;
failed credential deletion preserves the active owner and local records.

The optional CloudKit path is default OFF and unavailable without reviewed native
container/profile configuration. It never uses iCloud key-value synchronization.
Disabling sync or signing out leaves cloud records retained; explicit cloud-pin
deletion has its own cross-device confirmation and reset epoch. Local cleanup
does not erase historical device or Apple backups. See [candidate contract and
unapplied capability gate](icloud-pin-sync-198.md); native/signed cross-device
acceptance remains pending and #198 remains open.
