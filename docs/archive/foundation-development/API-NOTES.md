# Native Jellyfin API adapter

## Dependency and interface

Pin official `https://github.com/jellyfin/jellyfin-sdk-swift.git` **3.1.0**, revision
`50be9e583438be414a15d4bba933ff64b6769a91`, product `JellyfinAPI`.
The adapter also imports `Get` for the generated request type; link its product
if the project requires explicit transitive product visibility. SDK requirements:
Swift tools 6.0, iOS 16 / macOS 13 minimum, Get >=2.1.6 and
swift-nio-transport-services >=1.17.2. Root owns package resolution and project files.
No discovery, websocket, Quick Connect, or SDK connection helper is used.

`FoundationJellyfinLibrary.signIn(serverURL:username:password:)` returns a
`FoundationSession`; it does not persist automatically. Root calls
`FoundationCredentials.save(_:)`, `load()`, and `clear()` (all throwing static
functions). Restore reads Keychain only and makes zero network calls. Root owns
account replacement, view cancellation, and retained-page state. Account rejection
is exposed to the caller, without credential deletion or implicit sign-in.

The SDK README explicitly supports generated Entities/Paths with a custom network
stack. Here that stack is only one native ephemeral URLSession and a small request
translation function. Generated bodies, query parameters, endpoint paths and DTOs
remain authoritative. There is no connection manager, coalescer, admission gate,
retry, watchdog, retirement, cookie persistence, or custom cache. Native URLSession
configuration enables `waitsForConnectivity`, sets the request inactivity timeout
to 30 seconds, and sets the resource timeout to 60 seconds. These are platform
settings, not application timers or a promise of exact wall-clock completion.
The UI can still cancel its task while waiting. These API settings do not alter
AVPlayer's independently owned media loading.

## Media decision and limitations

`playbackURL` performs **zero network requests** and constructs the generated
`getAudioStreamByContainer` endpoint with `mp3`, `static=false`, `audioCodec=mp3`,
`audioBitRate=320000`, and automatic/audio stream copy disabled. This deliberately
requests MP3 encoding from the server. It is not lossless or original-file playback;
server transcoding permissions and an operational encoder are required. MP3 is a
native Apple-supported audio format. Unsupported encoding or denied playback fails
through AVPlayer; there is no silent codec, source, or transport fallback.

The server supports `ApiKey` query authentication for user access tokens, verified
in 10.10.7 and current source. The older `api_key` spelling is gated behind legacy
authentication in current server source and is intentionally avoided. No API token
is placed in an undocumented AVURLAsset header option. The authenticated media URL
is secret and may exist in memory only; never log, export, or persist it outside
Keychain session credentials. Server/proxy access logs are outside this app's control.

PlaybackInfo GET/POST is documented for media-source/device-profile negotiation.
This milestone does not need custom negotiation state: an explicit encoded audio
endpoint supplies one fixed supported representation. Therefore no PlaybackInfo,
opening/closing live streams, reporting timer, or play-session manager is added.
Live/external media and lossless selection are outside this milestone.

API URLs retain the user's HTTPS base path. Userinfo, query-bearing server URLs,
fragments, and non-HTTPS addresses are rejected. Generated item paths accept only
UUID/32-hex IDs, preventing catalog data from becoming path instructions. API
redirects are rejected by the native task delegate, including same-origin redirects,
so credential headers and sign-in bodies are not forwarded or replayed. Configure
the final canonical server URL at sign-in. AVPlayer owns media redirects and TLS;
the adapter never copies its token onto a redirected destination. This is not a
claim that native media redirects can be intercepted by this adapter. An authorized
server/proxy must not redirect playback to an untrusted destination with credentials.
No TLS override, ATS exception, or URL authentication challenge handler exists.

## Budgets and ownership

| Explicit event | Requests |
| --- | --- |
| Sign-in | One authentication POST |
| Keychain restore | Zero |
| Album page | One GET, limit 50 |
| Album track page | One GET, limit 100 |
| Retained view revisit | Zero; root retains returned page |
| Explicit refresh / next page | One GET for that page |
| Loaded track selection | Zero API resolution reads, plus native media traffic |
| Failed API operation | One attempt, no retry |

The server response offset, raw returned count, and total determine the next explicit
start index. A malformed/non-progressing page fails instead of looping. No hidden
page request, catalog caching, queue expansion, or artwork request exists. The
caller owns cancelling disappearing views; native `data(for:delegate:)` participates
in Swift task cancellation. Checks before and after the await reject late results.
Application cancellation does not prove that the native connection has drained.

Errors crossing the API boundary are finite categories and localized generic text.
DEBUG-only API events record auth/catalog family, one fresh ephemeral operation UUID,
and started/success/failed/cancelled outcomes with a finite error category. These
are adapter-operation events, not proof of on-wire starts or native cancellation
drain. All diagnostic statements/IDs are excluded from Release. No raw errors,
request parameters, or native metrics are recorded; diagnostics add zero requests.
Keychain uses a dedicated generic-password service, non-synchronizing,
AfterFirstUnlockThisDeviceOnly storage. Passwords exist only in the sign-in request;
they are never saved. Unit tests inject transport and use reserved example.invalid
addresses and synthetic content; they never load Keychain or connect to a server.

## Primary documentation

- [SDK README and generated Paths approach](https://github.com/jellyfin/jellyfin-sdk-swift/tree/50be9e583438be414a15d4bba933ff64b6769a91)
- [SDK package requirements](https://github.com/jellyfin/jellyfin-sdk-swift/blob/50be9e583438be414a15d4bba933ff64b6769a91/Package.swift)
- [Generated audio endpoint](https://github.com/jellyfin/jellyfin-sdk-swift/blob/50be9e583438be414a15d4bba933ff64b6769a91/Sources/Paths/GetAudioStreamByContainerAPI.swift)
- [Jellyfin Audio controller: explicit container, codec and static behavior](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/AudioController.cs)
- [Jellyfin 10.10.7 ApiKey authentication](https://github.com/jellyfin/jellyfin/blob/v10.10.7/Jellyfin.Server.Implementations/Security/AuthorizationContext.cs)
- [Current authentication spelling and legacy distinction](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Server.Implementations/Security/AuthorizationContext.cs)
- [PlaybackInfo GET/POST](https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/MediaInfoController.cs)
- [Apple supported media formats](https://developer.apple.com/documentation/avfoundation/avfiletype/mp3)
- [Native async URLSession](https://developer.apple.com/documentation/foundation/urlsession/data(for:delegate:))
- [Redirect delegate](https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/urlsession(_:task:willperformhttpredirection:newrequest:completionhandler:))
- [Keychain item accessibility](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)

## Verification status

Focused Swift formatting/lint passes. Synthetic XCTest coverage is supplied for
budgets, offset progression, generated sign-in body, fractional dates, empty pages,
URL construction, invalid IDs/servers, cancellation, finite auth/network/redirect
errors and no retries. Compile/test execution requires the coordinator's serial
Xcode slot and project wiring. No physical device, private server, installation,
Keychain mutation test, or playback reliability claim has been made.
