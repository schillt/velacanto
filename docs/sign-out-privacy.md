# Sign-out privacy — issue #30

**Status:** Open. Velacanto sends one authenticated `POST /Sessions/Logout` with the
current token in the Authorization header, then clears its local Keychain session
without waiting for the server. The request path contains no token; the focused
client test checks this. A successful response means Jellyfin accepted the request,
not that old-token rejection or every log destination has been verified.

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

Issue #30 remains open for a controlled old-token rejection check, deployed-server
version and log-sink review, offline sign-out validation, and broader signed-build
Keychain acceptance. Keep client request safety, server acceptance, and server
log safety as separate results.
