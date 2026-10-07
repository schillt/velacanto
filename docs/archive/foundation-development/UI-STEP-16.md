# Home owner corrections

Base/parent49214aa9c42e249f1582c8a72a53f5ab9b6342de. Isolated branch
codex/foundation-home-polish. Continue Listening deliberately unchanged after
owner clarification. Original app remains the Simulator reference.

## Presentation and deletions

Remove artwork ellipses from Home album cards; long-press/secondary-click menus
remain. Section titles and adjacent carets form one accessible navigation link.
Delete the explicit Refresh control and its revision propagation. The iOS Home
header places title/profile in one56-point row, fades when scrolling down,
returns when scrolling up; SwiftUI provides old/new geometry directly. No old
header controller/state machine imported. macOS retains native title/toolbar.

Profile and settings reuse the existing menu. An account image, initial or local
placeholder is loaded by its own visible destination. No new settings subsystem.

## Request budgets

Home genre selection: one request, capped at1000 genre summaries, Fields=ItemCounts,
MusicAlbum only. Require reported total==returned summaries, correct paging,
nonnegative album counts before ranking. Sort album counts
descending, title then stable identity as tie-break; retain at mostfive nonempty
genres. No per-genre requests to count contents, no paging loop or media scans.
The existing up-tofive visible album shelf requests are unchanged. Incomplete or
unsupported counts produce a local explicit-retry state, not a misleading rank.
This cap is a deliberate limitation for libraries with more than1000 genres.

Genre index is a distinct Home model; Library/Search alphabetical pages remain
unchanged. Retained loaded/empty Home makes zero additional metadata reads.
Profile cold entry: one current-user read plus zero/one optional image read.
Retained completed profile makes zero repeats. A recreated view may read again;
no new cache or retry. Hidden tabs and departed destinations cancel ownership.
Failures retain the placeholder and cannot affect audio or catalog sections.

## Evidence and limitations

Jellyfin's ItemSortBy has no count sort. Its genre repository pages before adding
counts, so ranking a first alphabetical page cannot establish the global five.
Count mapping uses the official SDK; all ranking stays inside the provider adapter.
Sources: Jellyfin.Server.Implementations/Item/BaseItemRepository.ByName.cs and
Jellyfin.Api/Helpers/RequestHelpers.cs in the official Jellyfin repository.

Only Home, library adapter additions and shared UI/profile composition changed.
Player, playbackURL, nativeLoad/responseData, credentials, actions, tests and
project/dependencies are unchanged. Existing checks run without new scaffolding.
Exact candidate gates and physical visual limitations belong to the persistent
build manifest. Local compilation is not device/network acceptance.
