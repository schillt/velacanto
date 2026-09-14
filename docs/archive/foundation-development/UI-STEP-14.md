# UI refinement candidate

Base1054151d3efa9a3853fe7f1b5b0527e6d3cba565. User requests clean recreation of old simulator design; lyrics remain excluded and cause of network trouble remains unproven.

Reference inspected live: original Home, Library, album grid, album detail, artist list/detail and Now Playing. Screenshots retained locally only, not published with personal media. New code changes only two existing presentation files: Library category icons/hierarchy, adaptive album/playlist cards, collection identity and prominent existing Play/menu, scrollable artist identity above existing albums, 44-point menus, spoken mini-player/timeline details and artwork-led Now Playing. No legacy code copied.

No player, URL, session, credentials, catalog model, action coordinator, debug tracing, test or dependency changes. Shared existing catalog models and explicit pagination remain. There is no artist biography/song API expansion, shuffle, local audio or volume restoration in this pass.

Request budget: unchanged single metadata page on a cold destination and zero for retained loaded/empty model reentry. Refresh/paging remain explicit. Album/playlist and artist headers add at most one existing tagged160px image attempt per instantiated live header; no tag means zero. Grid replaces row artwork with one existing attempt per instantiated tagged card. Native lazy containers may instantiate near-viewport content. Completed retained image views make zero repeats; reconstructed views may reload. No shared-cache or exact-pixel visibility guarantee. Now Playing's existing1024px load and lifetime unchanged; image is reused for crop/fade and background, no extra load.

During development owner reproduced a failure on installed candidate14, before these changes existed on any device. Three rapid skips with no outstanding instrumented API loads preceded native item timeout; next selection timed out too. Later Now Playing artwork failed. Owner confirms connectivity recovered without restart/reset and recalls original-app switching before returning to Foundation. This does not prove causation or native playback recovery. Physical app retained while root verifies UI separately.

Focused lint/diff and simulator compile passed; macOS build and all53existing synthetic checks passed. Remaining final visual, Release/exclusion and signing gates recorded in candidate artifact. No physical UI or reliability acceptance claimed from compile/model checks.

Visual review found and corrected a native-list disclosure squeezing Favorites
and duplicated collection title above its identity header. Favorites now uses
a captured presentation boolean with the same retained model/loader; collection
pages use inline native navigation and a plain list. Simulator sign-in required
normal Xcode signing (the initial unsigned binary could not access Keychain); no
credential code, special permission or debug bypass was added.
