# UI step 3: restore original navigation intent and artist portraits

Base: f791177722065b30ecd33c9eebfa3f53af067f91. Owner reports the prior
Library step working, then clarifies that the original product design must
remain the reference during reimplementation.

Restored Home, New, Library, Search in their canonical order and symbols.
Library starts selected and presents the original Your Music category hierarchy.
Albums and Artists work; Songs, Playlists and Genres are visibly disabled.
Home, New and Search are static not-enabled pages with zero feature requests.
This restores the navigational shell, not those features' data or behavior.

The compact Now Playing bar uses the native iOS26.1+ bottom accessory. It
preserves the original small artwork area, title/subtitle, Play/Pause, Next and
full-player access; inline placement hides Next as in the original. Earlier
systems use a safe-area bar. Track artwork is still a local placeholder: this
step does not add media metadata reads for the bar. Player implementation and
queue ownership are unchanged. This is structural/design-intent restoration,
not a claim of pixel-exact visual parity with the legacy app.

Artist rows now render circular portraits. Album and artist artwork share one
view and authenticated image path. Primary tags arrive with the existing artist
page (no extra metadata read); each tagged portrait uses the same requested
160x160 JPEG as albums. Missing or failed artwork remains a local placeholder.
No cache manager, retries, prefetch or independent URLSession was introduced.

Design references inspected: legacy AppNavigation.swift canonical order;
MusicLibraryNavigation.swift category title/subtitle/symbol hierarchy;
ModernPlaybackAccessory.swift expanded/inline native accessory composition.
No legacy controller/player/network source was linked into Foundation.

## Verification

- Lint and diff checks pass. Player/credentials diff is empty.
- 32 tests passed: 14 API, 9 player, 9 presentation. Artist tests now cover
  Primary tag hydration, shared authenticated image reads and no track reads.
- Initial iOS compilation caught native accessory isEnabled requiring26.1;
  availability was corrected and final signed iOS Debug compilation passed.
- Last UI-only amendment adds inline sizing/Next visibility. Deterministic
  tests preceded that amendment; final iOS compilation covers it.
- Independent static review found no playback/network blocker; its compact
  placement observation was addressed with native placement environment.

## Owner acceptance

Check original tab order, Library categories, circular artist artwork and the
mini player's controls/placement. Play from an artist album, switch to another
tab and return while skipping. Inactive placeholders should not load content.
No device visual or interruption-recovery success is claimed before owner test.

Final Release compilation and detailed diagnostic/test/legacy marker exclusion
checks passed. Signature verification passed. Final static review closes the
inline accessory observation. Logs: archive-local/foundation-shell-tests.log,
archive-local/foundation-shell-signed2.log, archive-local/foundation-shell-release.log,
archive-local/foundation-shell-lint2.log.
