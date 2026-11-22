# Sign-out privacy — issue #30

**Status:** Open. When attempted, server sign-out uses a bounded authenticated
`POST /Sessions/Logout` with the current token in the Authorization header and no
token in the request path. A focused client test checks the request shape. A
successful response means Jellyfin accepted that request, not that old-token
rejection or every log sink has been verified. Local cleanup and the server
outcome are separate results.

## Current source ordering

The standard app with the system credential backend uses a durable transaction.
It first attempts to verify the active account and record a sign-out intent. It
then retires scoped work and completes the required local cleanup before recording
cleanup completion, clearing the matching Keychain credential and removing the
intent. Only after that local transaction completes does it start a bounded server
logout attempt using the session captured in memory. The server result is reported separately when the
account context still matches. An interrupted process or a failure before the
attempt can leave server revocation unconfirmed; successful local cleanup does not
guarantee that a logout request reached the server or that an old token is invalid.

The legacy path, used when the durable transaction is not configured, starts a
server revocation task before attempting local Keychain deletion; it does not wait
for the server result before clearing local credentials. Starting the task does not
prove the request reached the server before deletion. If Keychain deletion fails,
the active account and pins are retained, but the already-started server attempt
may still succeed. Cleanup or credential failures can leave local sign-out
incomplete. A server failure leaves revocation unconfirmed; it does not by itself
establish whether local cleanup succeeded. See
[`FoundationApp.swift`](../NativeFoundation/Sources/FoundationApp.swift) and
[`FoundationCredentials.swift`](../NativeFoundation/Sources/FoundationCredentials.swift).

## Server log observation and source boundary

After a physical sign-out, the owner privately observed a token-bearing sign-out
entry in the live Docker Jellyfin log. No token or raw log line belongs in the
public issue, PR, or test evidence. The observation confirms logging on that
instance at that time; it does not establish the deployed version, current token
validity, log access by others, or public exposure.

In [Jellyfin v10.11.6](https://github.com/jellyfin/jellyfin/blob/v10.11.6/Jellyfin.Api/Controllers/SessionController.cs#L386-L397),
the logout route passes the authenticated token to the session manager. Its
[logout implementation](https://github.com/jellyfin/jellyfin/blob/v10.11.6/Emby.Server.Implementations/Session/SessionManager.cs#L1544-L1569)
logs the access token at Information level immediately before deleting the device
record. The same behavior appears in
[v10.10.7](https://github.com/jellyfin/jellyfin/blob/v10.10.7/Emby.Server.Implementations/Session/SessionManager.cs#L1470-L1495).
This is server behavior; changing Velacanto's request URL cannot remove that log
entry. Keeping server revocation is still preferable to silently discarding a
possibly valid token.

## Narrow operational mitigation

Treat existing Jellyfin and Docker logs, plus any shipped copies, as sensitive
until access and retention are reviewed privately. Protect the current copies;
a new logging setting will not erase them. Do not share matching lines as evidence.

For future sign-outs, the server owner can evaluate a source-specific Serilog
minimum-level override in Jellyfin's `logging.json`:
`Serilog:MinimumLevel:Override:Emby.Server.Implementations.Session.SessionManager`
set to `Warning`. Jellyfin documents
[`logging.json` as the custom configuration file](https://jellyfin.org/docs/general/administration/configuration/),
and [Serilog documents source-level overrides](https://github.com/serilog/serilog-settings-configuration#minimumlevel-levelswitches-overrides-and-dynamic-reload).
Preserve all other logging settings. This suppresses **all** Information and Debug
messages from that source, including useful session diagnostics; it is not a
single-message redaction. Verify the effective setting and every log sink with a
synthetic test session before relying on it. Jellyfin's
[troubleshooting guide](https://jellyfin.org/docs/general/administration/troubleshooting/#debug-logging)
distinguishes runtime reload of an existing file from a newly created file that
needs a server restart. No server setting was changed for this note.

Accepted #179 evidence covers the recorded local online/server-unreachable sign-out
and relaunch scope on Mac 317 and iPhone 316, including its pin-cleanup limits;
#219 separately covers the accepted reauthentication data-preservation repair on
316 with its stated limits. These results do not establish direct OS Keychain
deletion, a second-account/fault/migration matrix, forced OS callback timing,
old-token rejection or deployed-server log privacy.

Issue #30 remains open for a controlled old-token rejection check, the deployed
server's effective version and relevant log sinks, access and retention, and
broader exact-signed-build Keychain acceptance. Keep local cleanup, client request
safety, server acceptance, old-token rejection and server log safety as separate
results. This source-ordering correction adds no new runtime or server evidence.
