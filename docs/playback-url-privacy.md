# Playback URL privacy — issue #25

Owner disposition, 2026-10-27 UTC: retain current delivery for v0.6 and defer
token elimination to **v0.7.0**, GitHub milestone7. Issue25 remains open, now
assigned to that specific later milestone. This is a scope decision, not a fix
or proof of operational log protection. Active Project tracking reconciliation
is still pending; no release-disposition gate is claimed complete by this record.

**Status:** Open, P1, v0.6.0 milestone9. Live issue and all three comments
were reviewed on 2026-10-26 (2026-10-27 02:18 UTC). The prior owner deferral
was for v0.5.0 Alpha Preview; it does not waive the v0.6.0 work or release gate.

At evaluated local source `58b5cfe33445f2ffc9f01138ec4f52c515a5a3fc`, live remote
playback uses `FoundationJellyfinLibrary.playbackResource(for:)`, negotiated HLS
copy/AAC and `hlsURL`, which puts the account token in the `ApiKey` query value
handed to the native asset. The universal-audio `playbackURL(for:)` helper also
retains query authentication, but is a compatibility path, not the current live
remote delivery policy. Ready downloads can return a local file instead.
Construction is confirmed; exposure in any particular server, proxy, OS log or
receiver has neither been observed nor ruled out. This document does not remove
credentials from media URLs.

The [v0.6.0 options evaluation](playback-url-options-060.md) records current source
boundaries, public Apple/Jellyfin evidence, existing regression coverage, missing
acceptance and a concrete owner decision. No supported client-only replacement
was established. A transport exception and exact-candidate acceptance remain
necessary before implementation; no server or delivery change was performed.

## Protect and verify request logs

ADR [0006](decisions/0006-non-production-jellyfin-validation.md) requires
reverse-proxy and diagnostic logs to omit full URLs and query strings. Jellyfin
also [warns](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/)
that logging a full request path can disclose API keys. The server owner should
perform the following checks for each environment used for playback, including
the isolated validation server and any real server under their control:

1. Inventory every hop that can record an HTTP request target: edge or VPN
   ingress, load balancer, reverse proxy, Jellyfin host, and any log shipping,
   analytics, or monitoring service. Include access logs, request tracing,
   debug/error logs, and redirect/error-page logs. Record the configured log
   destination, format, access controls, and retention privately.
2. Configure access/request logging at every hop to omit the query string,
   preferably recording only the path and status. A rule that censors only one
   spelling of `ApiKey` is weaker: other query keys, casing, escaping, or a
   rewritten request can evade it. If query-free logging is unavailable, protect
   the entire log as secret material, restrict readers and retention, and keep
   this check unresolved. Jellyfin's proxy guides contain product-specific
   [Nginx examples](https://jellyfin.org/docs/general/post-install/networking/advanced/nginx/);
   review the effective configuration rather than assuming an example is active.
3. On an isolated test server, send a harmless request with a unique synthetic
   query marker, then exercise one authorized direct-play item and one item that
   transcodes. Search the locally retained logs and downstream log stores for
   the marker and for the test token **without copying matching lines into an
   issue or shared artifact**. The marker checks query omission; the playback
   requests check the actual media routes. Inspect effective logging settings
   for any route that the test did not exercise. Record only pass/fail by hop
   and log category, server version, and the test date.
4. Repeat after proxy, Jellyfin, or monitoring changes. If any hop retains a
   credential-bearing request target, restrict that log immediately and have
   its owner assess retention and access before reporting sanitized findings.
   Do not infer misuse from the presence of a URL in a protected log.

No configuration or log contents were available for this source review, so none
of these operational checks is marked passed. The app cannot enforce server or
proxy logging policy.

## Supported transport options reviewed

| Option | Public support and current limit | Decision |
| --- | --- | --- |
| Jellyfin `Authorization` header | Jellyfin's [authentication source](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Server.Implementations/Security/AuthorizationContext.cs) accepts it. Apple says `AVURLAssetHTTPHeaderFieldsKey` [is unsupported](https://developer.apple.com/forums/thread/671139); `AVPlayerItem(url:)` exposes no supported per-request header parameter. | Do not use the private asset option. |
| HTTP cookie on an `AVURLAsset` | Apple documents [`AVURLAssetHTTPCookiesKey`](https://developer.apple.com/documentation/avfoundation/avurlassethttpcookieskey) and notes that HLS requests can span paths or hosts. Jellyfin's authentication source does not read a session token from cookies. | A client-only cookie change cannot authenticate Jellyfin media. |
| `AVAssetResourceLoader` or an app proxy | Apple provides a [resource-loader delegate](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate/resourceloader(_:shouldwaitforloadingofrequestedresource:)), but using it to fetch authenticated media would create a new delivery implementation. | Unimplemented. The v0.6.0 owner decision must select a feasible supported path and authorize an isolated playback-freeze exception; prior preview deferral is not a current waiver. |
| Current `ApiKey` URL | Jellyfin's authentication source accepts `ApiKey`. Current live playback negotiates HLS copy/AAC and validates the returned route/session/source/device before adding the account token. AVPlayer owns fetching and seeking; the universal-audio helper is retained for compatibility. | Retain only as the existing behavior during investigation, with operational log protection. |

The source review does not establish how every Jellyfin version, transcode
playlist/segment request, redirect, background route, or AirPlay path propagates
authentication. A delivery candidate must use public APIs and be tested against
direct play, transcoding, seeking, background playback, and AirPlay on the exact
candidate and a controlled server. Automated tests must cover request creation
and credential-free diagnostics/Now Playing data. Physical acceptance and an
isolated exception to the playback freeze in [ADR 0012](decisions/0012-foundation-rebuild-and-playback-freeze.md)
are required before replacing the existing media path. Until then, issue #25
remains open.
