# Album duplicate filter local validation

Base: `7dcfd68`. VelaCanto Alpha 0.4.0 build 168, local candidate.

## Behavior

Profile & Settings → Library → Show Duplicate Album Tracks defaults off.
The shared projection matches album identity, disc number, positive track number,
and normalized title. Missing disc means disc one; missing/invalid track numbers
or titles remain visible. Different discs, titles and albums remain separate.
The stable first copy is retained; offline album browsing prefers an available
copy in the same logical position.

Phone and Mac album rows use the projection and show server track numbers.
Explicit album/artist Play, Shuffle and album queue addition use the same live
preference, including downloaded collection playback and CarPlay playback.
Changing the preference affects subsequent collection queues, not active queues.
Playlist entries are preserved even when their album metadata matches. Individual
song requests and All Songs remain available. No files or server items are removed.
Native CarPlay paginated album browsing retains raw provider rows and cursors;
its collection playback filters duplicates. Cross-page native browsing projection
is a separate follow-up, not an eager catalog scan in this patch.

Optional disc/track metadata survives catalog and download serialization. Older
saved metadata still decodes; unknown tags are not guessed or filtered. Provider
page cursors and original model membership remain unchanged.

## Verification

Strict formatting, diff checks and preflight passed (environment signing probe and
skipped Xcode probe warnings). Ten policy/persistence/provider tests and 36 library
action regressions passed on Mac. Independent read-only review found no remaining
scoped blocker after the captured-row playback identity guard was added.
Further build, simulator and installed-device evidence is recorded below when
complete. Synthetic checks do not establish acceptance of personal server tags.

## Frozen candidate

Runtime: `5f369d8`; final test candidate: `f44e00d` (subsequent commits only
correct native switch targeting and retained Library navigation in the new UI test).
The retained iOS simulator end-to-end test passed: default two rows/numbers 1,2
and two queue entries; enabled three rows/numbers 1,1,2 and three queue entries.
Earlier test attempts exposed test interaction/navigation mistakes; neither required
runtime changes. Signed builds and installed-device checks remain separate gates.

## Installation

Signed macOS and iOS Release builds passed from `f44e00d`, with runtime source
unchanged from `5f369d8`. Build 168 installed and launched on Mac and the authorized
iPhone 13 mini; stored data identities were preserved and the prior Mac bundle
was backed up. App identity and executable hashes are recorded in private local
provenance. Mac Profile & Settings visibly reported build 168 and the Library
switch off. A later Mac switch interaction was interrupted by owner navigation;
no separate Mac toggle-restoration claim is made. Album content remained browsable.
The physical iPhone install, installed-version verification and launch all succeeded.
Owner confirmation on an album with real duplicate tags remains a content acceptance
check; no physical audibility or server deletions were tested. No second CarPlay
session was opened. No GitHub branch/publication or distribution was performed.
