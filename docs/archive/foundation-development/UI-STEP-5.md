# Library completion candidate

Previous signed source: cc41d4a01b304344fa1a7f119b20974a9a5de962.
Common worker base: 23b654f96a4a9c1b42c350f5b592815de4912950.
Serially accepted contributions:

- Issue135 API/genres: 1db15ef4f8785e78e11e3ed4e25e7657a7406f46.
- Issue136 local pins/actions: 442aa3c1bf6d259ec4a37dcfbac3d009363150c3.
- Issue137 native macOS shell: 578a05b8326cb8f2ef92e6d020939f88db83b27a.

Root wires source-owned actions, shared menus/destinations, project membership,
local preference privacy declaration, packaged dependency notices, and the
Library categories. FoundationPlayer.swift, FoundationCredentials.swift,
playbackURL and the native send/session implementation are unchanged from the
previous candidate. No player, queue, transport or retry layer was introduced.

## Behavior

Genres page explicitly into albums. Pin/Unpin stores local source/account scoped
collection snapshots; restored pins do not pretend to know live favorite state.
Favorite/Unfavorite uses the generated Jellyfin mutation API, one request and
pessimistic confirmation. A successful mutation invalidates Favorites; only a
visible owner fetches. Source replacement cancels pending mutations and resets
retained page state. Pin persistence errors and item mutation errors stay local.

Menus expose the same supported operations through a visible button and native
context menu. Tracks call the existing loaded-queue Play behavior. Collection
Open uses shared destinations. Play Next/reordering and playlist editing remain
outside the frozen engine contract. Home/New/Search remain inactive.

macOS uses NavigationSplitView with one detail NavigationStack and existing
mini-player controls. iOS retains its native tabs/accessory. Pinned collections
currently appear as artwork rows under the original Favorites tile; matching
all original visual treatments is a subsequent presentation refinement.

## Simplification

One shared item row/menu/destination replaces separate catalog row branches;
unused row observation of playback was removed. The old macOS TabView fallback
is replaced by a small presentation-only native shell. Current instructions
replace contradictory milestone restrictions. Legacy source remains preserved
and unlinked; this is feature restoration, so production line count increases.

## Verification

Repository lint and diff checks pass. Native macOS Debug compilation succeeds.
All49 synthetic tests pass, covering API budgets, genre routes, response mapping,
source-scoped pins, mutation failure and deduplication, actual cancellation
forwarding, existing page ownership, duplicate occurrence selection and native
local audio. The first run exposed missing required Key fields in two synthetic
Jellyfin UserItemDataDto fixtures. Fixtures were corrected, including the negative
mutation fixture; production decoding was not relaxed. Prior default nativeLoad
Sendable-conversion warnings remain; no frozen transport change was made.

Independent integration review found no blocking source issue. It identified a
request-budget wording error: pinned rows may load bounded artwork at Library
root. CONTRACT.md now distinguishes zero metadata from pinned image reads.

Exact signed artifact records carry final Release/signing/install outcomes.
Physical iOS touch/menu stress and native macOS pointer/resize/back-navigation
acceptance are not inferred from compilation or synthetic tests.

## Dependencies

Jellyfin's official SDK3.1.0 directly depends on Get and Apple NIOTransportServices;
its remaining resolved runtime packages are Apple Swift packages. Native AVPlayer,
SwiftUI and URLSession remain the app's playback, UI and request implementations.
ThirdPartyNotices.txt contains exact pinned sources, full package licenses and
conservative transitive notices, available from Profile → Open-source licenses.
Packages are unmodified. The development generator is not bundled into the app.
Local-only preference access is declared with Apple's CA92.1 reason:
https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons
