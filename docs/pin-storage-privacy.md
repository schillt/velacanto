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
