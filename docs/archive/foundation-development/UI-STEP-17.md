# Search refinement and shared tab headers

Base1a2052f02bb5234ab80da0f1d883a632e6e9a443. Branch codex/foundation-search-refinement.

## Changes

Extract the owner-accepted Home title/profile backdrop into one SwiftUI modifier
used by Home, New, Library and Search. No old header controllers imported. Search
uses native Liquid Glass for the existing TextField on supported systems, native
material otherwise. While editing, its header stays visible. Remove root Refresh
controls and Search-result Refresh without changing detail-page controls.

Search has exactlytwo columns of1.6:1 genre cards, allowing taller accessibility
labels. No artwork ellipses; context menus remain. A stable pixel selection from
a4x4 thumbnail of the loaded artwork supplies a darkened tint which gradients
to solid behind the label. This is an artwork-color choice, not a new random
color on every redraw. Decode consolidation avoids processing ordinary artwork
when no tint is requested. Uses native CoreGraphics only.

## Request budgets and ownership

Search Browse Genres replaces alphabetical first-page loading with one complete
summary response capped at1000 genres. SDK ItemCounts supplies AlbumCount,
SongCount and ArtistCount; all three are validated and summed with overflow
checking. Counted genres sort by combined count descending, then title/identity.
Owner-approved missing-count behavior: uncounted genres remain alphabetically
after counted entries; Home uses known positive album counts only. Do not invent
a zero score or infer missing-count entries are empty. Incomplete responses and
invalid/overflowing counts still fail locally with explicit Retry. No per-genre count requests, catalog scans, paging loop, retries or new
transport. Combined counts describe catalog size, not listening frequency.

Home shares the helper but remains album-only and capped atfive. Library genre
paging remains alphabetical. Separate retained Search/Home/Library models avoid
sharing incompatible ordering. Cold Search summary: one request; retained loaded
or empty reentry: zero. Up to1000 small summaries are a deliberate response cap.
No automatic Load More is needed for the complete genre summary.

Artwork remains one tagged160-pixel read per visible card, cancellable; palette
adds zero requests. More compact cards can expose more images in the viewport.
Profile cold visible tab: one user read plus zero/one tagged profile image. Each
tab has its own view-owned profile; retained completed reentry is zero, recreated
views can read again. Hidden/obsolete destinations cancel ownership.

Search music replaces the mixed result page with three sequential typed requests,
each capped at five items, after the existing250ms debounce. No additional pages
load automatically. A caret beside a category title appears only when its page
reports more results; opening it explicitly starts one50-item category page,
with existing user-driven Load More. Loaded overview reentry makes zero metadata
reads; changing query replaces its owners and cancels obsolete work. Errors and
manual Retry remain local to each section. Existing DEBUG page attribution remains.
Remove the redundant Browse Genres heading and mixed-result grouping path.

Search track covers reuse supplied album references, consolidating the Home
projection. There is no album lookup: each visible result has at most one tagged
artwork read through the existing cancellable component. The preview has at most
15 result rows. The shared header lives on a stable container so switching from
genres to results does not replace the focused TextField. No new tests/dependencies or playback
changes. Existing deterministic checks and platform gates recorded with the exact
archived candidate. Physical focus, navigation restoration, tint contrast and
ranking remain device verification gates, not established by compilation.

Official evidence: Jellyfin SDK BaseItemDto exposes the three counts; official
Emby.Server.Implementations/Dto/DtoService.cs populates them for MusicGenre.

Physical investigation: complete summary response succeeded, but some entries
omitted counts. Temporary aggregate-only DEBUG probe confirmed this shape and
was removed. Official code can retain a genre without a count object; absence
does not prove emptiness. Owner explicitly approved the ordering described above.

## Follow-up: keyboard and loading presentation

Scrolling dismisses keyboard focus immediately; explicit Search selection or
field interaction restores focus. The native tab binding carries an activation
value, including first creation. Same-tab reselection requires exact-device
verification because SwiftUI does not promise a separate reselection callback.
No automatic focus restoration occurs on content loading or scroll completion.

All Foundation ProgressView spinners are removed. One shared lightweight native
placeholder pulses softly (static with Reduce Motion); queue mutation keeps plain
status and Cancel. Pending Search section titles are hidden until content or a
local error exists. No request, debounce, playback or transport behavior changes.

Owner confirms Search keyboard restoration works on device. Next presentation
refinement orders Search songs, albums, artists (and their serial loads in that
order). Shared skeletons show four fading rows, six rectangular genre cards in
two columns, or album-shaped shelf/grid content as appropriate. Request counts
and ownership remain unchanged; Reduce Motion still disables pulsing.

Header follow-up: remove the oversized fixed-height material backdrop. Its size
now follows the actual title/search controls, with top safe-area coverage and a
short fade inside its lower edge. No backdrop tail extends over the shelves or
genre grid. Header scroll/focus behavior and all request paths remain unchanged.

Genre color follow-up: choose the strongest chroma among the existing16 local
artwork samples, strengthen its hue and bound luminance for white labels. Replace
the old random swatch and blanket60% darkening. Overlay starts35% tinted, reaches
95% by45% of its diagonal and becomes solid at75%. No additional image reads.

Owner accepts richer colors; soften only diffusion so artwork remains visible:
20% tint at the upper-right edge,55% at55%,90% at85%, solid at the label corner.
Sampling and request behavior unchanged.

New alignment pass: remove shared per-item disclosure carets, preserving row
menus/open actions. New uses adjacent section-title carets only when more items
exist, shared Home/New album cards, aligned horizontal shelves, and existing
track-to-album artwork projection. Six track previews may now make up to six
small tagged artwork reads; expanded rows load their own visible tagged images.
No additional metadata reads, paging, retries or player/transport changes. Shared
card extraction removes duplicate presentation and preserves context actions.

Library reference pass: inspected original Simulator Library and album grid.
Recreate its mixed-case section headings, compact Pinned grid, and plain category
rows without List chrome. Pins reuse existing visible tagged artwork and context
actions; Favorites remains first. Accessibility uses two tile columns. Category
destinations retain existing loaders/models, native back navigation, and no new
metadata reads. Original-only local-file and listening-statistics features are
not introduced in this visual pass. Playback and transport remain frozen.

Library expansion: six Recently Added album cards below Your Music, reusing New's
retained recentAlbums model. Cold visible section: one existing metadata page;
retained reentry: zero. Up to six tagged cover reads, with explicit full-category
navigation only. Library Genres now shares Search's genre grid/card/placeholder
and destination owner. Library keeps existing alphabetical paging with explicit
Load More; Search retains its approved ranked summary. No extra lookup/retry.

Owner follow-up removes the remaining artwork-overlay menu from shared catalog
collection cards. Context menus retain the same actions; row menus remain. Home,
New and Library album cards now consistently have unobstructed artwork.

Album-artist consistency: Library already used /Artists/AlbumArtists; typed artist
Search used generic MusicArtist items. Both now share the existing album-artist
request helper, with SearchTerm and caller page limit. One request per artist
page remains; no catalog scan or local name merging. Explicit favorites/pins are
preserved. Standalone-artist inclusion beyond the server's album-artist set is
unresolved pending actual metadata evidence; do not infer it from missing counts
or rewrite song titles/artist names. Official ArtistsController documents the
AlbumArtists endpoint and searchTerm support.

Library Songs now shows supplied album artwork plus artist and album subtitle.
Each visible song cover uses the existing tagged image component; no album lookup
or metadata request added. Collection tracks retain their numbering. Catalog,
Songs and Genres use one native large-title destination modifier with back
navigation. Remove Refresh toolbar plumbing and redundant caller flags; local
Retry/Load More remain. Root title/profile headers are unchanged.

Artist/album imagery pass: inspected original Simulator artist fallbacks and
full-width album artwork fading into a dark title/control surface. Recreate one
shared image-owned hero with supplied Primary artwork and existing actions.
One640px header image replaces the smaller header read; no extra requests,
backdrop lookup, bio/similar-artist/artist-song fanout or playback changes. Existing
artist album grid remains; control behavior is specified in the follow-up below.
Tint is sampled during the existing decode. Missing image tags retain local
placeholders. Native back controls remain and macOS uses the same content.

Owner adds Play/Shuffle/Favorite control parity. Consolidate existing enqueue
collection paging into one source-owned expansion helper, also used by explicit
Play/Shuffle. Artist uses existing Items query with AlbumArtistIds and100-item
pages. Continue sequentially only for the explicit user operation, preserve
duplicates, validate advancing cursors, cancel through existing queue status,
and commit once complete. Native array shuffle; player internals unchanged.
No artist-track fetching occurs on appearance. More actions remain in toolbar.

Collection Play preparation observes the existing published selection only while
loading; any subsequent selection cancels it, including A-to-B-to-A and replay.
The temporary subscription is released before commit and at task completion.
Enqueue behavior is unchanged. Existing global queue status supplies preparation,
Cancel and errors; no extra status controller or player modification.

Detail surface correction: extend the artist/album scroll surface through the
top safe area with its existing artwork and tint; retain native navigation
controls. Track and local status rows use clear backgrounds, subtle separators,
aligned numbering and artist/album subtitles from already loaded metadata.
No new artwork or metadata reads, queue changes, player or transport edits.
Remove the user-rejected loaded-queue implementation note from track lists.

Main-tab header refinement: the existing scroll observation now controls
material opacity, clear at the top and increasing across the first32 points.
The page background remains visible at rest. Existing direction-sensitive
header visibility, Search focus, requests and playback remain unchanged.

Header polish: native thin material replaces thick material, with a20-point
fade extension and a gentler mask. Native scroll phase restricts direction
changes to active dragging; offset clamps to scroll bounds so rubber-band
rebound does not reveal the header. Returning to the top always restores it.
No player, request, queue or transport changes. Physical feel awaits review.

Owner finds the thin header too transparent: use native regular material and
retain full material through70 percent of its height, then diffuse through a
24-point extended edge. Preserve clear-at-top and intentional-drag behavior.
Presentation only; no playback, transport, requests or queue changes.

Follow-up: replace proportional gradient stops with a fixed32-point fade
below the header's full content height. Material stays unmasked behind text;
only the extra lower edge diffuses. Owner found the proportional fade too high.

Screenshot-confirmed header positioning correction: remove ignoresSafeArea
from the fixed-height material. Measure the actual header and top safe inset,
size the background to their sum plus32 points, then offset only by that inset.
This preserves coverage behind the full header and locates diffusion below it.
Regular native material remains translucent; scroll behavior is unchanged.

Artist overview: optional three-line preview with More opens native medium/large
material sheet; macOS gets a resizable reading sheet. One visible artist-detail
request via official SDK GetItem, zero requests on sheet expansion or retained
loaded/empty reentry. Cancellation discards late results. Missing/failed optional
text stays absent and never gates albums/playback. No retries, media changes,
new dependencies or test scaffolding. Physical server/UI acceptance pending.

Owner adds Appears On and More Like This artist shelves. Match Jellyfin Web:
ContributingArtistIds with album type and date/year/name descending; official
SimilarArtists endpoint capped at12. One12-item read per newly visible shelf,
retained loaded/empty reentry makes zero reads. Appears On has explicit Load More;
suggestions remain server-ranked/capped. Reuse catalog model and card actions,
local Retry, cancellable tasks and tagged artwork; no hidden catalog scan,
automatic retry or playback changes. Shared DTO mapping avoids duplication.

Owner approves taller artist imagery and personal Most Played shelf immediately
after biography: up to12 played tracks, two rows/six horizontal columns, server
PlayCount descending for the current user and album artist. One visible read;
no paging/scan, retained empty/loaded reentry makes zero reads. Existing small
track artwork and menu components; selection calls existing loaded-queue command.
No new playback reporting: ranking uses only history already recorded by Jellyfin.
Artist hero grows70 scaled points and exposes more image; album hero unchanged.

Artist polish: shared non-hero artist artwork clips to a true circle; suggested
artist cards use explicit150-point images for uniform layout. Biography opens
at medium native-material detent and expands to85 percent, below fullscreen.
Expanded background uses the existing artist tint, with native grabber/swipe
dismissal and accessibility escape. iOS Done removed; macOS retains Done because
its sheet has no grabber. No metadata/artwork request or player changes.

Artist-page typography: center related artist names under circular portraits.
Omit album-card artist subtitles on artist destinations; Most Played rows show
only their supplied album subtitle rather than repeating artist names. Other
surfaces retain subtitles. No request, metadata, queue or player changes.

Owner clarifies expanded About may reach the native large detent. Replace85
percent with large while retaining sheet presentation, visible grabber and
interactive dismissal; expanded artist-color background remains unchanged.

About uses Apple's actual glassEffect(.regular) for its sheet background on
iOS26+, including iOS27, with container-relative shape. Older iOS retains
regular material. Native sheet/grabber, detents and expanded solid artist tint
are unchanged; no requests, player or queue changes.

Native-controls pass: artist/album Shuffle and Favorite use glass button style
and Play uses glassProminent with circular borders on iOS/macOS26+. Prior
circular treatment is retained only on older systems. Existing action closures,
queue loading disables, favorite state and accessibility labels are unchanged.
Header modernization stays separate for owner comparison. No network or player
changes; only the shared detail controls are in this candidate.

Owner accepts native detail buttons; reduce secondary Shuffle/Favorite label
frames from52 to44 points. Play stays72 points. Native style and action paths
remain unchanged. Header replacement is assessment only in this candidate.

Native header comparison: iOS26+ shared tab header uses safeAreaBar and soft
scroll-edge effect, hidden at the top or when the title is hidden. No hand-drawn
material/mask/offset/opacity ramp runs on modern iOS. Stable bar height prevents
visibility changes from adjusting safe area; existing intentional-drag handling,
clamped rebound and Search focus exception remain. Older iOS keeps the accepted
manual fallback. macOS native title/toolbar remains unchanged. No network or
playback changes. Exact-device top, bounce, Search and contrast checks pending.

Launch correction: initial root selection is Home instead of Library, on both
platforms. Foregrounding retains current in-memory selection. Existing Home
visibility-driven loads run normally; no new loader, refresh or player changes.

Owner extends artist layout to albums: overview below hero/controls and related
albums after the track list. Consolidate overview and recommendation components
and neutral adapter methods for both item kinds; share collection cards. One
optional canonical overview read and one capped12-item SimilarAlbums read per
newly visible section, zero on retained loaded/empty reentry or sheet expansion.
Use supplied album-artist exclusion as Jellyfin Web does, with no lookup.
Keep cancellation and failures local, no autoplay/scan/retry or player changes.
Existing album track paging, duplicate occurrences and queue actions unchanged.

Album recommendations now use two rows in the horizontal carousel, up to six
columns for the existing12 results. Shared shelf accepts two-row presentation;
artist shelves retain one row. Matching two-row loading placeholders. Same
recommendation query/order and commands; artwork remains visibility-owned.

Album toolbar More actions includes View Artist when an album-artist reference
is supplied. Reuse the existing captured destination navigation. Now Playing
passes its already-known artist reference into View Album so that route also
retains the action. No discovery request, guessing, playback or queue changes.

Song ellipsis and long-press menus now include View Album and View Artist from
supplied references. Shared rows, Home history, Most Played and queue entries
route into existing destination views. Missing references omit the action; no
identity guessing or menu-time lookup. Queue occurrence commands are unchanged.
Cold and warm menu opening both cost zero requests; explicit navigation uses
the destination's existing visible-page read and artwork budgets. No new cache,
retry, prefetch or playback changes. Device navigation acceptance remains pending.

Owner refinement: remove generic Open menu copy. Collection actions explicitly
say View Album, View Artist, View Playlist or View Genre. Album cards also offer
View Artist from their supplied reference, including Home/New and Search rows.
The same menu content serves ellipsis and native long-press presentations.

Album and artist detail names gain a compact native toolbar title when the
measured hero text passes the measured toolbar edge. Album toolbar includes
artist subtitle. Native Liquid Glass capsule on iOS/macOS26+, material fallback;
short fade respects Reduce Motion. Existing back and menu controls remain.
No catalog requests, playback changes or new test scaffolding. Zero additional
cold/warm request budget; device scroll/layout acceptance remains pending.

Track menus omit View Artist on artist pages (including Most Played) and View
Album on album pages. Pass the current page kind explicitly to the shared menu;
other destinations and standalone/search/queue menus remain available. No
environment inheritance into sheets, new requests or playback changes.

Detail title refinement: plain title text, no glass bubble or material capsule.
Keep a hidden plain-text measurement placeholder until the hero names pass the
toolbar. Disable the principal item's shared background on current platforms.
Compact text rises/scales into place with a short damped spring; Reduce Motion
removes spatial motion. Delete the superseded title-glass modifier. This is a
compact handoff transition, not a matched-geometry flight across view hosts.
No request or playback changes. Exact-device appearance pending owner review.

Artist artwork correction: supplied album-artist references omit image tags,
but Jellyfin Primary images accept an optional tag. Permit one bounded image
read for visible untagged artists using their existing ID. No metadata lookup
or automatic retry; tagged requests retain their version tag. Newly visible
untagged artist image budget changes from zero to at most one image request;
retained loaded/failed view reentry stays zero. Playback/transport unchanged.

Owner extends the verified artist image correction to albums. Permit a bounded
Primary image request for an album ID without a tag, including supplied track
album references. Tagged images preserve their tag; no metadata lookup or retry.
Newly visible untagged album artwork budget is at most one image request; retained
completed view reentry stays zero. Playback and native transport remain frozen.

Profile icon now opens a native settings sheet across all tabs. Existing
Now Playing, licenses, internal-only diagnostics and Sign Out move out of the
context menu into grouped sections. A separate settings file owns its child
sheets; root no longer owns their flags. Profile name/photo reuse the visible
header's successful load; opening settings adds zero cold/warm requests. Native
medium/large detents and grabber on iOS, sized macOS sheet. No playback changes.

Now Playing presentation: native iOS full-screen cover with zoom transition
anchored to the mini-player album artwork; macOS retains native sheet sizing.
All existing player entry points use one presentation modifier. Native zoom
owns interactive dismissal, with explicit Close and Reduce Motion fallback.
Mini-player now uses the shared artwork view (one160px read per new album view).
Player hero uses the same640px renderer/color sampling as detail pages, deleting
the duplicated DEBUG/Release artwork loaders and blurred-image background.
One visible hero image read, zero metadata lookups/retries; retained completed
views do not reload. Separate mini/hero resolutions remain separate reads.
Playback/queue/transport code unchanged. Physical gesture and layout acceptance
remain required on the signed candidate; no simulator reference app replacement.

Player refinement: starting tracks only changes the existing queue/bar. Remove
auto-presentation flags/covers from catalog, New, Search and Most Played, and
unused Home shelf bindings. Explicit mini-player, Continue Listening and settings
entry points remain. On iOS replace Close arrow with a two-second grabber that
fades; retain native zoom dismissal and accessibility escape, macOS Done. Move
transport lower and add disabled native volume slider solely for spacing review.
No volume/audio behavior added. Native zoom handles platform accessibility.
No additional requests; avoiding auto-presentation also avoids its hero reads.

Now Playing main canvas is a fixed viewport, not a ScrollView. Controls keep
their intrinsic height at the bottom; artwork takes the remaining space. Remove
fixed hero-height and spacer assumptions that pushed controls past the viewport.
Use tighter spacing for shorter windows and bounded title/artist/album lines.
Native zoom receives vertical dismissal gestures without a competing scroll
view. Queue and catalog destinations retain their normal scrolling. No playback
or request changes. Device fit and swipe acceptance remain owner checks.

Main-tab persistence: Now Playing and queue album/artist links dismiss their
modal presentation, then route into the selected tab's main NavigationStack.
Delete both player-owned catalog destination trees. Queue dismisses before the
player; presentation onDismiss performs navigation without timers. Main browsing
explicitly retains the native tab bar, macOS retains its sidebar. Settings closes
when its player routes back to browsing. No duplicated tab bar or player changes.
Destination reads remain visible-owned; no added request or cache mechanism.

Enable native tabBarMinimizeBehavior(.onScrollDown) on the modern iOS tab/accessory
shell. Existing accessory placement handling already uses its compact form and
omits Next when inline. The system owns collapse/expansion; no scroll tracking,
extra animation state, network or playback changes. Older fallback and macOS
remain unchanged. Physical scroll behavior remains owner acceptance.

Compact-tab positioning: adopt native typed Tab declarations and give Search
the .search role. This lets iOS position active tab, bottom accessory and Search
in the native leading/center/trailing compact arrangement. Existing selection
binding and Search reactivation remain; no custom positioning or duplicate tabs.
iOS18 minimum supports the Tab API; macOS keeps its existing sidebar. No new
requests or playback changes. Device layout/reselection checks remain pending.


## Bounded New genres and Library listening shelves

Owner requests genres with new music after New albums, and most-listened albums
in Library. New derives at most six unique genres, in newest album order, from
the retained first24 recent albums. Request Genres in that existing response;
no genre-summary or per-genre lookup. Cards reuse a contributing album cover
through the existing visible artwork component (at most six image reads).
Genre selection opens the existing genre destination. Missing genre metadata
omits the shelf; no guessed identity or compensating request.

Library replaces its recent-album preview with a separate retained model. One
visible request for100 played tracks sorted by user PlayCount descending; group
supplied album references, sum supplied counts and retain12. This is a bounded
sample, explicitly labeled in UI, not an exhaustive whole-library ranking.
No hidden pagination, album lookup or new reporting. At most12 visible cover
reads. Loaded/empty model reentry makes zero metadata reads; explicit Retry
owns one new attempt. Existing task cancellation and local errors remain.
Frozen playback, transport and credentials unchanged; no legacy code copied.
