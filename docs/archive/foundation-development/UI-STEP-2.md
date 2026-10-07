# UI step 2: Albums and Artists navigation

Base: 6b16535dde2c29681a14e9e3db7fea8ddfad50aa (artwork-only candidate).
Owner requests navigation tabs and artist browsing and authorizes automatic
installation of ready builds. Preserve both earlier signed candidates.

Two native tabs now expose Albums and Artists. Artists means album artists;
opening one shows its album collection, then the existing album track view.
The loaded-track queue and player are unchanged. Mini player access remains
available in both navigation stacks. Additional tabs, artist songs aggregation,
artist portraits, search, favorites and genres are not in this step.

A shared catalog list replaces the album-only list instead of adding a separate
artist loading implementation. Root tab models preserve loaded pages including
empty results. Tab selection is explicit input to each destination's owned task;
inactive tasks are cancelled and cannot consume pending page actions. There is
no hidden-tab loading or new retry/control layer. Existing post-await generation
and cancellation guards remain in place. See CONTRACT.md for request budgets.

## Jellyfin compatibility

Artist pages use the documented /Artists/AlbumArtists compatibility endpoint
with the pinned SDK's generated query parameters, 50 items per page and no
images. SDK 3.1.0 deprecates its helper toward Persons; that replacement is not
interchangeable across older servers. The narrow documented request avoids
warning suppression, server discovery, or an additional compatibility manager.
Artist albums use generated GetItems with albumArtistIds, not ParentId. All
requests use the existing authenticated URLSession implementation.

Primary reference: Jellyfin's official ArtistsController retains the endpoint:
https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/ArtistsController.cs
Pinned SDK GetAlbumArtistsAPI.swift and GetItemsAPI.swift specify query encoding.

## Verification

- Lint and diff checks passed.
- macOS Debug compiled; all 31 tests passed (14 API, 9 player, 8 presentation).
- New coverage checks artist endpoint/filter/paging budgets, invalid IDs with
  zero reads, local failures, inactive-tab no-read behavior and independent
  retained empty pages. Player tests pass unchanged.
- Independent read-only review found no source blocker.
- Existing non-Sendable default-function conversion warnings also appeared in
  the prior artwork build; they are not new to this change.

## Owner device check

Browse Artists → artist → album, play, rapidly skip and select queue tracks.
Switch between Albums and Artists while nested and while content loads; return
to the prior destination and confirm content and mini player placement. Scroll
album artwork with playback. Model tests cannot establish actual SwiftUI
navigation cancellation or physical request counts. No physical pass is claimed.
