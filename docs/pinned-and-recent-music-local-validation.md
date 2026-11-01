# Pinned and recent music local validation

Base: `5476e33`; runtime candidate: `865471f`; VelaCanto Alpha 0.4.0 build 165.
Local development only; no alpha/beta publication or release promotion.

## Delivered

- Mac Library sidebar includes Pinned, using the existing account-owned pins,
  offline availability filtering, collection destinations and Favorites action.
- Pinned artwork fills rounded squares for all supported item kinds. Artist
  circles elsewhere and shared artwork caching/loading are preserved.
- Visible artist-logo test diagnostics removed; contrast decisions retained.
- Recent music selection includes a track from each bounded recent group before
  filling remaining slots, preserving server group order, deduplication and
  cancellation. This fixes a demonstrated omission where the first large album
  occupied all 24 slots; cache identity advanced to prevent reuse of old selection.

## Checks

- FoundationLibraryTests: 91 passed, no failures (Mac).
- Final signed iOS and macOS Release builds passed; strict formatting/diff checks
  passed. Preflight: zero failures, two environment/signing-probe warnings.
- Build 165 installed and launched on the authorized iPhone 13 mini and Mac;
  existing bundle identities and app data preserved.
- Independent read-only UI review: no scoped blocking issue.
- Actual Mac Pinned navigation and Favorites tile destination verified. Duplicate
  Pinned heading removed and final shared refinement built for both platforms.
- Mobile pinned artist appearance still needs owner visual confirmation; the
  signed phone install and launch do not establish visual acceptance.

## Unresolved New Tracks server feed

Owner comparison confirms fresh build 165 does not match Jellyfin Suggestions
→ Recently Added Music. New Tracks is **not accepted as fixed**. The bounded
selection correction does not establish that the server returned the desired
recent groups or that album track order identifies a newly added song.

With owner permission, compared All music libraries with the specific available
Music library on Mac: results changed, but still did not match the reported
Suggestions example. Original All music libraries selection restored and verified.
Owner subsequently observed questionable recent ordering in Jellyfin itself;
server metadata/order remains an investigation, not a proven server diagnosis.
Do not hardcode titles, infer new import dates, or replace this feed with an
unverified sorting heuristic.

Primary source contracts reviewed:
- [Jellyfin music Suggestions request](https://github.com/jellyfin/jellyfin-web/blob/master/src/apps/legacy/controllers/music/musicrecommended.js)
- [Jellyfin React music section](https://github.com/jellyfin/jellyfin-web/blob/master/src/utils/sections.ts)
- [Jellyfin latest-media endpoint and legacy delegation](https://github.com/jellyfin/jellyfin/blob/v10.11.0/Jellyfin.Api/Controllers/UserLibraryController.cs)
- [Jellyfin latest-media parent/filter handling](https://github.com/jellyfin/jellyfin/blob/v10.11.0/Emby.Server.Implementations/Library/UserViewManager.cs)

The sources support Audio selection, explicit parent handling and grouped latest
media; they do not prove the owner's exact server version/configuration or dates.

## Build 166 supersedes the grouped New Tracks selection

Owner explicitly verified **Date Added ascending** as the desired ordering. This
supersedes the earlier newest-first/grouped-album interpretation; ascending is
intentional, not a claimed newest-first sort. Runtime source:
`d5f929666fec054598ff97e0121fc52b9d85a393`.

New Tracks uses the existing paginated track endpoint, with `DateCreated` and
`SortName` ascending, matching Jellyfin's Date Added mapping. The grouped album
expansion helper and its obsolete tests were removed. Recent albums remain
descending; CarPlay's grouped recent-music feed remains unchanged. New Tracks
cache identity changed to prevent older grouped selections from being reused.

- [Jellyfin Date Added mapping](https://github.com/jellyfin/jellyfin-web/blob/master/src/apps/legacy/controllers/music/songs.js)
- 87 FoundationLibraryTests passed, including ordering, native cursors and invalid
  offset checks; independent read-only review found no scoped blocker.
- Missing Mac pinned artists resolved by owner: those artists were pinned only
  on the phone. Existing per-installation pin storage is unchanged.

Final signed macOS and iOS Release builds passed. Build 166 installed and launched
on both authorized targets with app data preserved. The retained iOS UI test for
provider ordering and explicit playback passed. Fresh Mac New Tracks data loaded
under the restored All music libraries selection; owner comparison with Jellyfin's
ascending Date Added list remains pending. Build 165's unmatched feed is not
evidence of build 166 acceptance. Strict lint/diff checks passed; preflight retained
zero failures and two environment/probe warnings.
