# Search candidate

Base1ea0c8f158cc10318d4027926851a0d537d88374 (New07). Owner approved UI work
continuing with no repair for the separately reproduced track-specific stream
error. GitHub139 tracks Search; this is not a playback or compatibility fix.

API worker commits f5f0dfc43812eb02590a40d2979fe64ac4a9fdd6 and
8bfd7bd52eb1cac4ab7ecea276f881137f5d0c5b were integrated serially, then root
wired native SwiftUI presentation and existing components. No legacy code or
test implementation was imported. No new tests, fault injection or scaffolding.
The existing genre metadata check was updated for its newly supplied image tags.

## Actual design reference

The legacy app was inspected live in the simulator at empty Search and populated
results: rounded search field, two-column Browse Genres artwork cards, and
Artists/Albums/Songs groups with visible item menus. The query was cleared after
inspection. This is reference evidence, not a claim that the new exact-candidate
UI has passed physical or simulator interaction acceptance.

Search uses a native TextField and shared FoundationCatalogView rows/destinations.
The grouped presentation retains original item offsets for loaded-track queue
selection. Genre cards use existing tagged images and match the prior top-left
collage presentation; no sampled album requests or custom image pipeline. Cards
adapt columns for macOS width; visible/context Pin/Open actions remain available.

## Ownership and budgets

Search after250ms uses one50-item generated Items request for tracks/albums/artists.
Changing the trimmed query synchronously replaces the existing page object and
view task identity. Captured query/model values and cancellation checks prevent
old-query publication into new results. Same retained query reentry is zero-read;
Load more follows the actual cursor. There is no separate search controller,
cache manager, request lane, automatic retry or hidden expansion.

An empty Search field uses the same retained genre model as Library: one50-item
page on cold entry, zero when already loaded/empty. Its response includes one
Primary tag per item; instantiated tagged cards use existing160px JPEG reads.
Clear cancels query ownership. Source replacement discards query and page state.

## Review and gates

Independent review found a missing genre image identity reset. Root added the
existing item-plus-tag identity pattern, preventing refresh/reorder from keeping
another genre's image. No remaining blocking source issue reported. Query/stale
ownership review was static, not a new test harness.

Lint/diff, native macOS compilation and all53 existing checks pass. Player source,
credential source, playbackURL and the full send/native-session tail match the
base exactly. Final signed artifact records hold iOS Release exclusion/signing
and installation outcomes. No private-device reliability rate is inferred.
Home remains inactive and advanced queue features remain outside this step.
