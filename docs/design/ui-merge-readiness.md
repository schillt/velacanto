# Native UI merge record

**Reviewed:** July 29, 2026
**Status:** Implemented; validation remains

This note records the boundary between Velacanto's playback and Jellyfin
foundation and the approved Apple-platform interface direction, followed by
the result of implementing the first native UI merge.

## Outcome

The native shell was implemented without rewriting the playback, session, or
Jellyfin foundations.

- The app builds against the iOS 27 Simulator SDK.
- All 28 playback and Jellyfin foundation tests pass on macOS.
- `AudioPlaybackCoordinator` and `JellyfinSessionController` already live at
  app scope, which is the correct ownership model for persistent navigation and
  a mini-player.
- `VelacantoRootView` now provides native iOS tabs and a native macOS split
  view, with real Home, Library, Search, profile, mini-player, and Now Playing
  surfaces.
- Authenticated artwork, source-neutral playback history, and current
  Jellyfin data replaced the prototype's fictional content.
- New and Radio were intentionally omitted because they did not yet have useful
  production behavior.

## Native interface contract

- Design for the current iOS, iPadOS, and macOS 26-27 system appearance.
- Prefer standard SwiftUI navigation, presentation, controls, materials,
  semantic colors, typography, and SF Symbols.
- Let system components provide Liquid Glass automatically. Apply explicit
  glass effects only to a small number of custom navigation or playback
  controls that need them.
- Keep Liquid Glass in the functional layer. Content, artwork, lists, and
  reading surfaces remain in the content layer.
- Do not recreate system tab bars, sidebars, toolbars, search controls, sheets,
  menus, forms, or settings surfaces with custom drawing.
- Keep the current iOS 18 and macOS 15 deployment targets unless a separate
  product decision deliberately raises them. Gate APIs introduced in version
  26 and provide native fallbacks.
- Adapt the shell by platform while sharing feature models and behavior.

## Existing foundation to preserve

- Direct local-file playback without importing or copying media.
- Source-neutral playback requests and app-level player ownership.
- Play, pause, stop, seek, elapsed time, duration, Now Playing metadata, and
  system media commands.
- Jellyfin URL validation, connection, authentication, prompt-free private token
  storage, session restoration, and logout.
- Jellyfin library, album, and track browsing with loading, empty, retry, and
  error states.
- Jellyfin stream resolution and handoff to the shared playback coordinator.

The existing Jellyfin `Form`, `List`, `Section`, `NavigationLink`,
`ProgressView`, and `ContentUnavailableView` surfaces are already appropriate
native building blocks. They should move into the new shell rather than be
rewritten as custom controls.

## Required work packages

The implementation followed these work packages. Platform quality validation
and complete real-server smoke testing remain open.

### 1. Establish the platform app shell

- Establish `VelacantoRootView` as the production root.
- Introduce shared app destinations and platform-specific containers.
- Use native iPhone tab navigation and independent navigation stacks per tab.
- Use a native macOS sidebar, toolbar, commands, and Settings scene.
- Preserve the app-scoped playback and Jellyfin controllers.

### 2. Add the real artwork pipeline

- Decode the Jellyfin image metadata required for albums and tracks.
- Build authenticated artwork URLs through the Jellyfin API boundary.
- Add a reusable artwork view with native loading, failure, and placeholder
  states.
- Cover image metadata and request construction with tests.
- Do not ship the fictional design-prototype artwork as library content.

### 3. Add persistent native playback presentation

- Present the active item through the native tab-view bottom accessory on
  supported iPhone releases.
- Adapt the accessory between expanded and inline placements.
- Provide a native fallback on older supported releases.
- Keep play, pause, stop, seek, error, and accessibility behavior connected to
  `AudioPlaybackCoordinator`.
- Give macOS an equivalent toolbar or bottom playback surface appropriate to
  the platform.

### 4. Build the artwork-led Home experience

- Use real playback and library data.
- Keep direct entry points for Jellyfin and local files.
- Define honest empty and signed-out states.
- Treat Continue Listening and Recently Played as data features, not static
  decoration. Add the necessary provider or local history model before showing
  populated sections.
- Move account access into native toolbar, sheet, menu, and Settings surfaces
  as appropriate.

### 5. Integrate the existing Jellyfin browse flow

- Place connection and account management in the new navigation hierarchy.
- Add artwork to library, album, and track presentation.
- Preserve loading, retry, empty, expired-session, and playback-error behavior.
- Verify the complete connect to browse to play journey against a real server.

### 6. Validate platform quality

- Add native UI tests for primary navigation and playback presentation.
- Check Dynamic Type, VoiceOver, increased contrast, Reduce Transparency,
  Reduce Motion, light and dark appearances, and minimum target sizes.
- Exercise iPhone, iPad, and resizable macOS layouts.
- Verify the interface on both version 26 and 27 platform runtimes where
  available.
- Repeat background playback and system-control smoke tests after the shell
  changes.

## Decisions required before the shell is considered complete

1. **Navigation scope:** The approved concept includes Home, New, Radio,
   Library, and Search, while the 0.1 roadmap defers Search and several related
   features. Do not ship dead or decorative destinations. Either bring a
   minimal useful version into the milestone or introduce each destination
   when it becomes functional.
2. **Home history source:** Decide whether Recently Played and resumable content
   come from Jellyfin, a local source-neutral playback history, or both.
3. **Deployment policy:** Retain the current compatibility range with
   availability gates, or record an explicit decision to require platform
   version 26 or newer.
4. **macOS 0.1 depth:** Confirm whether the new macOS shell is release-quality
   or remains compile- and smoke-tested for the first milestone.

## Merge acceptance gate

The first UI merge is ready when:

- real local and Jellyfin actions are reachable from the new shell;
- playback persists across top-level navigation;
- the mini-player reflects the shared playback coordinator;
- no production screen depends on fictional metadata;
- iPhone and macOS use native platform navigation;
- Liquid Glass remains limited to the functional layer;
- existing foundation tests pass and primary UI tests are added;
- the complete signed-out and signed-in journeys have been smoke-tested.
