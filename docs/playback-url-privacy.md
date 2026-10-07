# Playback URL privacy — issue #25

**Status:** Open. On `alpha` at `88e603de78e2a63a2d7d62a888b0935adac733bb`,
`FoundationJellyfinLibrary.playbackURL(for:)` puts the Jellyfin session token in
the `ApiKey` query parameter of the native media URL and hands that URL to
`AVPlayerItem`. This source behavior is confirmed. Exposure in a particular
server, proxy, device log, or receiver has not been observed or ruled out.
This document is an operational mitigation and an investigation record; it
does not remove the token from playback URLs.

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
| `AVAssetResourceLoader` or an app proxy | Apple provides a [resource-loader delegate](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate/resourceloader(_:shouldwaitforloadingofrequestedresource:)), but using it to fetch authenticated media would create a new delivery implementation. | Defer unless a supported simpler path is excluded and an isolated playback-freeze exception is approved. |
| Current `ApiKey` URL | Jellyfin's authentication source accepts `ApiKey`. The current universal-audio endpoint lets Jellyfin choose direct delivery or conversion while AVPlayer owns fetching and seeking. | Retain only as the existing behavior during investigation, with operational log protection. |

The source review does not establish how every Jellyfin version, transcode
playlist/segment request, redirect, background route, or AirPlay path propagates
authentication. A delivery candidate must use public APIs and be tested against
direct play, transcoding, seeking, background playback, and AirPlay on the exact
candidate and a controlled server. Automated tests must cover request creation
and credential-free diagnostics/Now Playing data. Physical acceptance and an
isolated exception to the playback freeze in [ADR 0012](decisions/0012-foundation-rebuild-and-playback-freeze.md)
are required before replacing the existing media path. Until then, issue #25
remains open.
