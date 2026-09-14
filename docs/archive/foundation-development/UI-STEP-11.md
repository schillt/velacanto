# Favorite and AirPlay

Base90a1e3cf94cd16cb8217e5f0db8ca44cf9178188 (owner reports currently reliable).
Two explicitly requested controls added to reduced Now Playing. Favorite reuses
existing pessimistic source-owned mutation: zero reads on page opening, one
explicit mutation per tap, pending disabled, existing local error presentation.
No new load, cache, retry or state controller. Existing favorites consumers keep
their prior invalidation behavior.

AirPlay is a thin AVRoutePickerView representable. iOS uses the system audio
route picker; macOS associates the existing AVPlayer as required by the SDK.
No custom discovery, route/session observer, activation, polling or new player.
System route discovery/streaming is platform-owned, outside catalog read budgets.
No MPVolumeView, lyrics or album/artist destination reintroduction.

Player, library API/transport, source actions, journal, credentials and artwork
loader are unchanged. No dependencies or tests added. Existing synthetic checks,
macOS/iOS compile, Release exclusion and signing recorded in artifact12. Owner
checks initial playback, skips/queue, favorite/unfavorite, then opening/dismissing
AirPlay and selecting/returning from a receiver if available. A passing local
build does not prove device routing or explain the rejected candidate10 failure.
