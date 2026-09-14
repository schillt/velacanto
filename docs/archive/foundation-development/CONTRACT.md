# Current Foundation contract

This consolidated contract replaces the historical milestone exclusions. The
owner approved the minimal rebuild, reported successful playback, then approved
incremental restoration of the original UI. ADR0012 and AGENTS.md define the
frozen boundaries and coordinated work rules. The preserved legacy base is
702b7e87cbe11436ec2f83c1a7a5b72d8c57fe5c; the last prior Library candidate is
cc41d4a01b304344fa1a7f119b20974a9a5de962.

## Product and ownership

Use one native AVPlayer and the existing neutral catalog interface. Jellyfin
request construction, authentication, DTO mapping and media URLs stay in its
adapter. No new playback state machine, admission layer, watchdog, retry,
speculative paging or feature-owned session is permitted in this UI milestone.
Preserve queue occurrence identity and the existing player commands. Playback,
media URL construction, transport setup, credentials and audio session are frozen.

Library supports albums, artists, songs, playlists, favorites and genres. Pinning
is local and account/source scoped. Favorite writes are explicit and publish only
after server confirmation. Unknown favorite state stays unavailable until known.
Every context action has a visible menu equivalent; macOS supports secondary
click and a native sidebar. New restores recent tracks/albums and Search is enabled as specified below;
Home is enabled with retained catalog shelves.
Playlist editing, arbitrary reordering, shuffle/repeat, offline media and new
providers remain separate work, not no-op controls or queue-replacement tricks.

## Request budgets

| User event | Cold work | Retained loaded or empty re-entry |
| --- | --- | --- |
| Library root | Zero metadata reads; pinned album/artist row artwork follows the bound below | Zero metadata |
| Placeholder tab | Zero network reads | Zero |
| Albums, artists, playlists, favorites | One metadata page, at most 50 items | Zero |
| Genres | One genre page, at most 50 items | Zero |
| Artist or genre albums | One filtered page, at most 50 items | Zero while model retained |
| Songs, album tracks, playlist tracks | One page, at most 100 items | Zero while model retained |
| Explicit Refresh or Load more | One bounded page | Explicit action bypasses retention |
| Pin or Unpin | Zero network; local persisted state | Zero |
| Favorite or Unfavorite | One explicit mutation; no retry/readback | Successful mutation invalidates Favorites for its next visible load |
| Loaded track selection | Zero metadata reads; existing native media traffic | Same |

A destroyed destination can perform a new page read on reopening. Pagination
retains its actual cursor; there is no whole-catalog scan or hidden expansion.
Mixed Favorites playback queues only loaded tracks and preserves selected
occurrence. Unsupported playlist media fails locally without a filter scan.

Each instantiated album/artist row, including local pins at Library root, with
an image tag owns at most one 160-pixel
JPEG request per uninterrupted lifetime. Retained completed rows do not retry;
destroyed rows may load again. Missing tags, tracks and genres make zero image
reads. Native List may instantiate near-viewport rows. This is not a global cache
or exact visible-pixel guarantee. Artwork failure remains a local placeholder.

Navigation/source changes cancel obsolete owned reads. Generation checks prevent
late publication. Source exit cancels explicit mutation ownership. No background
refresh is triggered merely to update hidden Favorites. Pins survive app restart
but cannot transfer across source/account identity. Persisted pins carry no
credentials and do not claim a current server favorite value.

## Acceptance and diagnostics

Root integrates serially and tests the combined candidate on both platforms.
Synthetic tests do not restore real credentials or contact a private server.
Verify frozen source comparisons, lint, focused deterministic tests, native
macOS compilation, iOS signing and Release diagnostic exclusion. The owner tests
the exact installed candidate before the next feature integration.

Next device journey: browse every Library category, open genres/albums/artists,
pin/unpin then relaunch, use long press and visible menus, change a favorite and
re-enter Favorites, explicitly page and refresh, and navigate with rapid existing
playback controls. Check warm and empty destinations. macOS additionally needs
sidebar, back navigation, resize, pointer and keyboard acceptance.

The bounded internal journal is enabled initially in DEBUG with an off toggle;
its detailed instrumentation, UI and synthetic launch mode are absent Release.
Record finite categories/counts only, never origins, account/item identifiers,
credentials or personal media names. No diagnostic network requests or polling.
Report device evidence separately from deterministic tests and compilation.

## Owner-approved New tab (candidate07)

Owner reported candidate06 functional before authorizing this step. Two separate
existing page models hold recent tracks and recent albums. Each instantiated,
active section owns one cold24-item page, newest DateCreated first. No inactive
tab reads, no hidden pagination and no automatic refresh/retry. Loaded or empty
models retained by the source root make zero metadata reads on reentry, including
See all. This is retention, not a timed freshness cache; use explicit Refresh.
Each section Retry or See all Refresh/Load more makes one bounded page; New's
overall Refresh requests one page per active section. A failed/stalled track
section does not gate album loading. Cancellation prevents late publication.

Presentation shows six tracks and five album cards, independently of page24
fetch bounds. Play queues already-loaded tracks using the existing occurrence
selection. See all reuses each exact model/cursor and the shared catalog view.
Album art uses the existing160px request displayed at144points; no new rendition
request, image cache, retry or session. Shared visible/context menus remain.
The frozen player/URL/transport/credentials and inactive Home/Search are unchanged.

## Owner-approved Search (candidate08)

Base1ea0c8f158cc10318d4027926851a0d537d88374. Keep the separately reproduced
track-stream error outside this UI step. Live legacy simulator Search was reviewed
for layout: rounded field, genre-card grid, grouped Artists/Albums/Songs results.
No legacy implementation or test harness is imported.

Each settled nonempty query owns one50-item Items page after250ms; only Audio,
MusicAlbum and MusicArtist are requested. Whitespace-only input makes zero search
requests; empty Search can request one existing50-item genre page. Library and
Search share the retained genre model. A changed trimmed query synchronously
replaces its simple page object and task identity; cancelled work cannot publish
into the new page. Same retained query reentry makes zero new metadata reads.
Explicit Load more uses the returned cursor; no hidden expansion. Retry is
explicit, with the same250ms delay while no initial page exists. Refresh bypasses
retention. No timed cache, replay, new controller or networking layer.

Genre pages now include Primary image tags from that same request, one image
type/limit1. Existing tagged160px JPEG loading serves instantiated genre cards
and rows; no album-page sampling. Missing/failed artwork remains local. Genre
collage presentation uses the top-left region to match the original design.
This supersedes earlier genre zero-image statements, not metadata page budgets.
Source replacement still resets all retained views. Grouped song Play preserves
original loaded occurrence indices. Playback, media URL, native transport,
credentials, Home and advanced queue features remain unchanged.


## Owner-approved Home and queue additions (candidate09)

See UI-STEP-8.md. Play Next/Last permits direct queue-array additions and moves
while preserving the current native audio item. Whole albums/playlists expand
sequentially on explicit request, with Cancel, before one atomic addition. No
media URL, session, credentials or playback pipeline change. Home reads existing
server history; this step adds no playback reporting. Historical step notes above
describe their own candidates.


## Candidate10: full Now Playing

Restores large artwork, track/album details, favorite and destination menus,
native scrubbing, transport, volume/AirPlay, and expandable queue and lyrics.
See UI-STEP-9.md for request budgets, exact lineage, and verification limits.


## Candidate11: reduce Now Playing after failed device run

Owner requested full sheet, artwork/text metadata, basic controls and queue only.
Lyrics, AirPlay/native volume, favorite and album/artist navigation are removed
from Now Playing with unused code deleted. Candidate10 is not accepted. See
UI-STEP-10.md. This comparison does not establish a root cause or verified repair.


## Candidate12: Favorite and AirPlay

Owner reports reduced candidate11 currently reliable. Restore only Favorite via
existing actions and native AVRoutePickerView. Other removed features stay out.
See UI-STEP-11.md; physical acceptance is pending.


## Candidate13: View Album and View Artist

Now Playing's menu opens existing album/artist destinations from supplied neutral
references. No new canonical lookup, lyrics or volume widget. See UI-STEP-12.md
for request scope and owner verification.


## Candidate14: internal page-attribution journal

Behavior matches candidate13; DEBUG journal tags page origins, request purposes,
cancellation requests and completion/publication. No new requests or recovery
logic. Lyrics still absent. See UI-STEP-13.md.
