# Playback URL credentials: v0.6.0 options and decision — #25

Superseding owner decision, 2026-10-27 UTC: retain current delivery for v0.6;
token elimination is explicitly deferred to **0.7.0 (milestone7)**. The live issue
was moved and remains open. The evaluation below is preserved as the evidence
preceding that choice; its earlier decision-pending statements are historical.
Project-field reconciliation remains pending. No server or app-relay transport
experiment is authorized by this deferral, and no token elimination is claimed.

Evaluation date: 2026-10-26 America/New_York; live issue verification at
2026-10-27 02:18 UTC. Evaluated local base:
`58b5cfe33445f2ffc9f01138ec4f52c515a5a3fc`.

## Result and scope

**#25 remains open, P1, in milestone9 (v0.6.0).** The live
[issue](https://github.com/schillt/velacanto/issues/25) and all three comments
were read through the GitHub connector. Its v0.5.0 Alpha Preview deferral is
historical scope approval, not a v0.6.0 waiver. Completing this evaluation does
not complete token elimination, acceptance or milestone disposition.

No supported, client-only header/cookie substitution was established for the
current native HLS path against an unmodified Jellyfin server. Do not remove
`ApiKey` while assuming that PlaybackInfo, PlaySessionId, a prior URLSession
request or Keychain sign-in authenticates subsequent AVPlayer media requests.
Do not implement the private header option. The smallest public Apple option
is cookie-authenticated native delivery, but it needs a new server contract;
stock Jellyfin's inspected authentication path does not implement that contract.

This is a bounded architecture/options evaluation, not a vulnerability scan or
transport patch. Runtime sources, SECURITY.md, server configuration, credentials,
players, devices and delivery workflows were not changed. No real-server request
or log inspection occurred. Public documentation/source retrieval is the only
network research. No external leak or compromise is established.

## Current source proof

Paths below are relative to the evaluated base; line numbers describe that source.

| Boundary | Current behavior and implication |
| --- | --- |
| `NativeFoundation/Sources/FoundationApp.swift:684` and `FoundationDownloads.swift:1353` | The account player asks downloads for a resource; a ready owned file returns locally, otherwise the library supplies remote playback. Download-first for every track would change startup/storage policy and is not a streaming fix. |
| `FoundationLibrary.swift:1730`–1919 | `playbackResource` resolves streaming quality and negotiates HLS. PlaybackInfo disables direct play/direct stream and selects copy or AAC. The adapter rejects required custom HTTP headers. Copy preparation fetches a master through its own authenticated request, validates its single child and then returns the child URL. That preparatory request does not authenticate later native requests. |
| `FoundationLibrary.swift:2187`–2243 | `hlsURL` accepts an API-relative audio master route, preserves the validated server/proxy base and checks item/source/session/device identity. It removes both `apikey`/`api_key` spellings, then appends the current account token as `ApiKey`. `hlsCopyURL` reuses this validation and changes the path to the validated main playlist. This substitutes an account credential; it does not remove one. |
| `FoundationLibrary.swift:2247` | Compatibility `playbackURL` returns universal-audio query authentication. It is not the account's current remote playback policy. |
| `FoundationPlaybackPreferences.swift:180` and `FoundationPlayer.swift:619` | The resource URL reaches an `AVURLAsset` with the public cellular option and then `AVPlayerItem`; no header injection, cookie setup or resource-loader interception is implemented. |
| `FoundationLibrary.swift:2515` | App-owned metadata/negotiation/cleanup requests use `Authorization: MediaBrowser` via URLSession. Their header transport is distinct from native HLS fetching. Playback preparation bypasses optional browsing admission. |
| `FoundationPlayer.swift:1187`–1215, 1268–1339 | Player failure UI uses a fixed message; failure diagnostics classify known errors. DEBUG access-log projection emits fixed delivery/type categories and numeric aggregates, not event URI/server/error strings. This does not control Apple's own logs or receiver diagnostics. |
| `FoundationNowPlaying.swift:119` | System `MusicContent` is built from occurrence UUID, title/artist/album, duration and artwork; it does not use the playback resource URL. No claim is made that arbitrary catalog text cannot itself contain sensitive text. |
| `FoundationJournal.swift:5`–55 | The DEBUG journal is bounded, but `record(String)` is not a general redaction filter. Privacy relies on callers projecting safe categories/numbers. Do not describe it as sanitizing arbitrary errors or URLs. |

## Public supported options reviewed

Sources were read on the evaluation date. Jellyfin `master` links below describe
the inspected public implementation, not proof of the owner's deployed version
or all supported server releases. A release-pinned fetch was unavailable through
the browsing tool; repeat the relevant source/API check against the exact isolated
server version before a runtime experiment. No production version was queried.

| Option | Evidence and conclusion |
| --- | --- |
| Native arbitrary authentication header | [Apple engineering response](https://developer.apple.com/forums/thread/671139) explicitly says `AVURLAssetHTTPHeaderFieldsKey` is unsupported. The current local iPhoneOS SDK `AVAsset.h` public initialization keys also do not declare it. `AVURLAssetHTTPUserAgentKey` is a user agent setting, not a credential channel. No supported arbitrary-header replacement was established. |
| Public cookies | [`AVURLAssetHTTPCookiesKey`](https://developer.apple.com/documentation/avfoundation/avurlassethttpcookieskey) and current SDK comments document cookies for asset HTTP(S) requests, subject to domain/path policy, including HLS subresources. This can keep credentials out of request targets. It does not make an unmodified server accept them. Cookies remain credentials and must not be logged. |
| Jellyfin header/cookie auth | Inspected [`AuthorizationContext`](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Server.Implementations/Security/AuthorizationContext.cs) extracts a MediaBrowser token and query authentication, with legacy header/query forms conditional on server configuration. It does not extract an authentication token from cookies. Copying the token into a cookie client-side is insufficient. Basic/Digest credential challenges are not a demonstrated substitute for this token parser. |
| PlaybackInfo/session grant | Inspected [`MediaInfoHelper`](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Helpers/MediaInfoHelper.cs) assigns a GUID PlaySessionId and generates TranscodingUrl using the existing claims token. This is session correlation, not a scoped expiring media grant. Inspected [`DynamicHlsController`](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/DynamicHlsController.cs) is authorized. Removing the query token without another recognized credential has no demonstrated authentication basis. |
| Short-lived token or signed URL | No native scoped expiring playback-grant endpoint was established in the inspected playback/authentication sources. [`ApiKeyController`](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/ApiKeyController.cs) creates elevated API keys, not an item/expiry-limited playback grant. [Quick Connect](https://jellyfin.org/docs/general/server/quick-connect/) is sign-in authorization, not proof of a short-lived media token. A newly designed signed URL would reduce account-token exposure but still be a bearer credential in the URL. |
| Resource loader / app relay | Apple exposes a [`resource-loader delegate`](https://developer.apple.com/documentation/avfoundation/avassetresourceloaderdelegate). Its existence does not establish a supported transparent interceptor for every native HTTPS HLS request or receiver fetch. A relay would need to own fetching/rewriting and cancellation. Neither is implemented or validated here; no claim of HLS/AirPlay feasibility is made. |
| URLSession headers / completed local downloads | App-owned requests can use the existing authenticated transport. That does not configure AVPlayer's independent fetching. Replacing streaming with full local downloads would introduce startup, storage and cleanup costs and does not satisfy unchanged streaming behavior. |

## Concrete implementation decision

**Recommend first authorizing an isolated server-cookie feasibility candidate**
if changing the supported-server contract is acceptable. It preserves AVPlayer's
native HTTPS HLS loading rather than immediately introducing an app media server.
This is a proposal; no server change or transport exception is authorized by this
record. There is no small app-only production patch ready to merge.

The bounded first candidate would use a disposable controlled Jellyfin server
and a separately reviewed cookie-auth extension/gateway: an authenticated,
app-owned request creates an opaque, expiring, item/session-scoped media grant;
the asset receives that grant only through the public cookie option. The server
must recognize it for all playlists, segments and initialization/key resources,
validate each requested scope, and ensure responses/redirects never reintroduce
an account token or signed bearer in any URL. Existing Jellyfin-generated
credential queries therefore require explicit server handling. A gateway that
only adds an upstream header while forwarding credential-bearing manifests does
not solve the issue.

Keep grants memory-scoped, domain/path limited, HTTPS-only and absent from shared
cookie persistence; design expiration/renewal and account retirement explicitly.
Native cookie updates, background playback and receiver behavior must be proved,
not assumed. Reject cross-origin redirects or unrecognized resources without
forwarding the grant. A failed proof must leave the current accepted runtime
untouched and report the exact incompatible action.

The owner decision has three concrete alternatives:

1. **Server contract change (recommended first feasibility path):** authorize the
   disposable cookie-auth prototype and a playback-freeze exception. Costs are a
   server extension/gateway, scoped-grant lifecycle, manifest/redirect handling,
   compatibility/version policy and a full physical route matrix. General stock
   Jellyfin compatibility cannot be claimed until an upstream/server capability
   exists and capability negotiation/failure UI is designed.
2. **Keep arbitrary stock Jellyfin support:** authorize a separate app-relay
   feasibility investigation. It needs bounded streaming/range forwarding,
   allowlisted manifest/subresource rewrite, strict origin validation, account
   cancellation and memory limits. Loopback reachability/background suspension
   and AirPlay receiver fetching are unresolved go/no-go questions. A resource
   loader is not assumed to solve these. Do not estimate this as a header-only
   patch or begin implementation without the isolated exception.
3. **Accept the remaining URL risk for a later milestone:** explicitly select a
   named later milestone and approve the residual risk, update the issue and
   active Project consistently, and complete the operational log inventory in
   `playback-url-privacy.md`. This is a scope decision, not completion. No such
   v0.6.0 decision is recorded here; the current release gate remains blocked.

A short-lived signed-URL prototype could be considered only as a separately named
risk-reduction option. It must not be reported as eliminating token-bearing URLs.
TLS, Keychain storage and log redaction likewise do not eliminate URL credentials.

## Regression coverage and acceptance gaps

Existing tests were inspected, not executed in this documentation-only task.
No Xcode, native/device or hosted test lane was used.

| Existing production seam / test | What is covered; remaining gap |
| --- | --- |
| `FoundationLibraryTests.testHLSComparisonNegotiatesAndRetiresOnlyItsServerSession` | Negotiation/source/session, synthetic token query and exact cleanup. It asserts current URL authentication, not credential elimination. |
| `testMP3CopyPlaylistRejectsEncodingAndUnsafeVariants`, `testHLSComparisonRejectsUnsafeOrMismatchedNegotiatedURL`, `testOriginalPreferredHLSSelectsCopyOrAACBeforeNegotiation` | Identity/origin/path/variant rejection and copy/AAC policy. They do not inspect native request propagation, actual server logs or receiver authentication. |
| `testPlaybackURLUsesNoTransportAndPreservesBasePath` | Universal compatibility request construction, including synthetic query token; not proof of the live remote path's privacy. |
| `testPlaybackReportsUseOfficialEndpointsAndBoundedPayloadWithoutURLCredentials` | App reporting URLs/bodies. It does not cover HLS URLs. |
| `FoundationPlayerTests.testNativeRateDiagnosticDropsUnrecognizedPayloads`, `testSessionDiagnosticCategoriesDiscardUnknownPayloads`, `testSessionErrorDiagnosticsAllowOnlyKnownDomainAndCategory` | Unknown native diagnostic payloads are projected to safe categories. No end-to-end sentinel assertion for all failure/journal paths was established. |
| `FoundationNowPlayingTests.testTextCommandsBoundariesAndDuplicateOccurrenceOwnership` | Native metadata uses occurrence identity and expected text/artwork. No dedicated credential-bearing resource sentinel test was established. |

The smallest safe implementation-independent follow-up is targeted regression
coverage through existing injected resolvers/transports: use synthetic URL/token
sentinels in resolution errors and successful HLS copy/AAC resources; assert fixed
failure UI, captured journal output and system content contain neither URL nor
sentinel. Verify native access-event projection stays an allowlist. Do not make
tests invoke real servers, weaken current request validation or assert a generic
journal redactor exists. These tests would protect output boundaries only.

Before #25 completion, the selected exact candidate must additionally establish:

- Credential-free URLs for initial media, every HLS child/segment/init/key,
  redirects, failure paths and queue transitions; synthetic per-hop assertions and
  private controlled-server/proxy log inspection with sanitized pass/fail evidence.
- Successful Original/copy and fixed/Auto AAC behavior, direct/universal behavior
  if retained, seeking/ranges, repeated queue advancement, account cancellation,
  grant expiry/renewal/revocation, and no added dependency on optional loading.
- Audible iOS/macOS playback while browsing, background/lock, relevant network
  paths and AirPlay with multiple tracks/seeks on the exact installed candidate.
  A running timer, synthetic test or source-only review is insufficient.
- Both platform regression/build gates and Release diagnostic-exclusion checks;
  physical acceptance and owner review of the explicit transport exception.
- Operational redaction/retention verification at every participating hop. No
  such verification, physical acceptance or release disposition is marked passed.

Local verification for this record is documentation/link/source consistency and
`git diff --check`. No issue update, closure, push, installation or publication is
part of this evaluation. The maintainer/owner must choose and authorize the next
runtime path or explicitly disposition the issue before release.
