# Library collections and explicit playback freeze

Base: c88fd9ee2fbc2f9c1b311174a7b3a62a10a15494. Owner reports this build
working and authorizes Songs, Playlists and Favorites, clear source boundaries,
and the old simulator as a design reference. Automatic installation is approved.

Restore the original Pinned Favorites tile above Your Music. Songs and Playlists
are now enabled; Genres and other unfinished tabs remain inactive. Favorites
open mixed saved albums, artists, playlists and songs. Song taps queue only
already-loaded songs. Playlists preserve server order and repeated occurrences.
No favorite writes, playlist mutation, pin management or hidden expansion.

The album track UI became one track-list presentation reused for Songs and
Playlists. Catalog mapping supports explicit allowed kinds with the same loader.
Favorites retain source occurrence offsets when filtering loaded songs into a
queue. Non-audio playlist entries currently fail locally as unsupported; no
filtering scans or metadata fan-out were introduced. See CONTRACT for budgets.

## File boundaries

- FoundationPlayer.swift: frozen native playback/queue engine.
- FoundationPlayerView.swift: Now Playing/queue presentation and state labels.
- FoundationBrowseModel.swift: existing page ownership and retained content.
- FoundationArtworkView.swift: shared local artwork presentation/task ownership.
- FoundationViews.swift: navigation shell and Library/collection presentation.
- FoundationLibrary.swift: Jellyfin catalog adapter and existing transport.
- FoundationCredentials.swift: Keychain; FoundationJournal.swift: DEBUG evidence.

Extraction moves existing behavior, without new coordinators or control layers.
An access modifier on the shared presentation label was widened for cross-file
use. The player engine, playbackURL and entire existing transport/decode tail
were compared exactly with the base and are unchanged. Playback changes require
a separately identified reason and owner discussion under the new freeze rule.

## Verification

Lint/diff checks and macOS Debug compilation passed. All 37 tests passed:
18 API, 9 player, 10 presentation. Added coverage includes bounded Songs,
Playlists and Favorites reads, invalid input without reads, playlist duplicate
order, local failure, and mixed favorites selecting the correct song occurrence.
Independent read-only review found no blocker and verified source membership.

Xcode was opened on this project. The installed legacy app was launched in the
simulator and its Home shell was observed; subsequent CUA navigation was
unreliable, so this is not a claim of full live Library visual comparison.
Original Pinned/category source presentation was used as design reference,
without importing old controllers or network implementations.

Device acceptance: open Songs, play and burst skip; open a playlist and select
repeated/nonconsecutive entries; open Favorites and navigate each available
kind. Switch tabs while loading and playing. Confirm Favorites tile placement.
No new physical reliability or visual pass is claimed before owner testing.

Primary playlist semantics reference:
https://github.com/jellyfin/jellyfin/blob/master/Jellyfin.Api/Controllers/PlaylistsController.cs

Final iOS Debug signing and Release compilation passed. Release binary checks
exclude detailed journal/test/legacy markers. Logs: foundation-collections-tests.log,
foundation-collections-release.log, foundation-collections-signed.log and
foundation-collections-lint2.log under /private/tmp.
