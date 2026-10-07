# Velacanto 0.3 native-player design

## Intent

Velacanto should feel like a current Apple-platform music player while retaining
its own identity and personal-library focus. Apple Music is a reference for
information hierarchy and interaction vocabulary, not a visual asset source or
a requirement to reproduce every feature.

Use native SwiftUI and Apple-designed components wherever they express the
intended behavior. Prefer system layout, typography, materials, controls,
animation, focus, and accessibility behavior over custom replicas.

## Navigation

### iPhone

- System `TabView` with Home, Library, and Search.
- Search uses the semantic search-tab role.
- Active playback uses the system tab-view bottom accessory.
- Full Now Playing is presented from the accessory; Up Next is reachable from
  Now Playing without adding another primary destination.

### iPad

- Use adaptive system tab/sidebar behavior rather than stretching the iPhone
  tab layout.
- Preserve useful content when the app enters compact multitasking widths.
- Use system split presentation or an inspector for Up Next when space permits,
  with a compact modal fallback.

### Mac

- Preserve `NavigationSplitView`, the always-available global library search,
  and Profile in the sidebar footer.
- Sidebar selection replaces the active detail context rather than changing
  content behind a pushed detail.
- Use a native inspector or equivalent secondary presentation for Up Next.
- Do not recreate a fixed custom sidebar, tab bar, toolbar, or settings window.

## Screen contract

### Home

Show only real data:

1. Continue Listening when a restorable current item exists.
2. Recently Played from source-neutral local playback history.
3. Favorites from the active library provider.
4. Recently Added from the active library provider.
5. Music source entry points.

Omit empty shelves when their absence is self-explanatory. When the entire page
has no useful content, show one honest signed-out, empty, offline, or error state
with a direct recovery action.

### Library and Search

- Retain Albums, Artists, Songs, and Playlists.
- Album collections use stable artwork grids; song-oriented collections use
  native lists.
- Search presents grouped albums, artists, songs, and playlists and rejects
  stale results.
- Every representation of the same item uses the same capability-driven action
  vocabulary.

### Music details

- Use artwork, title, artist/secondary metadata, Play, and Shuffle as the
  leading hierarchy.
- Follow with the provider-authoritative track or album list.
- Use native toolbar/menu actions for Favorite, Play Next, and Play Last.
- Do not show unsupported or decorative actions.

### Mini-player and Now Playing

- The mini-player remains concise: artwork, title/artist, and play/pause.
- With a playable current item, present it once at the root playback boundary
  across Home, Library, Search (including active query/result interaction), and
  catalog details. Do not duplicate it per destination or hide it as a side
  effect of navigation. Full Now Playing intentionally replaces it; signed-out
  and no-current-item states reserve no empty accessory space.
- Now Playing owns full artwork, metadata, scrubbing, previous/play/next,
  favorite, shuffle, repeat, playback-method information, errors, and Up Next.
- Playback method uses neutral language: Local File, Direct Play, Direct Stream,
  or Transcoding. It is informational, not a prominent warning.
- Up Next permits reordering and removal only after the current item.

## Action vocabulary

| Action | Album/artist/playlist | Song | Now Playing |
| --- | --- | --- | --- |
| Play | Primary | Row activation | Resume/current |
| Shuffle | Primary where a collection exists | Not applicable | Toggle upcoming order |
| Favorite | Menu/toolbar when supported | Menu/swipe/context | Direct control |
| Play Next | Menu when playable | Menu/swipe/context | Not applicable to current |
| Play Last | Menu when playable | Menu/swipe/context | Not applicable to current |
| Remove/reorder | Not applicable | Up Next only | Up Next presentation |

## Native component rules

- Use semantic colors and system type styles; cyan remains the app tint.
- Let current SwiftUI navigation and playback chrome provide system materials.
- Reserve explicit glass effects for the few custom playback surfaces that
  cannot use system chrome directly.
- Use SF Symbols for commands and always provide accessible labels.
- Avoid fixed sizes except bounded artwork targets and minimum window geometry.
- Prefer `ViewThatFits`, adaptive grids, layout priorities, and system spacing
  over device-name conditionals.
- Honor Reduce Motion and Reduce Transparency; motion must communicate state,
  not decorate it.

## State and accessibility requirements

Every data surface defines loading, populated, empty, retryable error, terminal
error, signed-out, and offline behavior. Mutating actions define in-flight,
success, failure/rollback, and rapid-replacement behavior.

Essential controls require meaningful VoiceOver labels, minimum target sizes,
keyboard/focus behavior where applicable, and readable results at supported
Dynamic Type sizes. Color and icon shape cannot be the sole indication of
favorite, playback, error, or selection state.

## Historical references

The initial fictional prototype, screenshots, generated artwork, and merge
record are retained under [`../archive/`](../archive/README.md). They preserve
project history but do not define the 0.3 interface.
