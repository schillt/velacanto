# New tab candidate

Base: d28543a92e30014ce8b647a814e4f382f38ff907 (Library06).
The owner reported that build functional before approving New; this is an owner
report, not a measured stress reliability rate. GitHub task138 tracks this step.
API worker: 5ee1c381576e5959ba02356b51aa0b9a5c52d305, same exact base/parent.
Root integrated it as39078049ea33bec4aae428d93dcdf20e1a50e23d, then qualified
JellyfinAPI.SortOrder after compilation found an Apple type-name collision.

## Implementation and budgets

A small FoundationNewView owns presentation, using existing source-retained page
models, shared item menus/destinations, and existing player commands. No new
network lifecycle, controller or playback abstraction. The adapter adds two
24-item generated Items queries sorted DateCreated descending, one for tracks
and one for albums; all prior query defaults remain unchanged.

Six tracks display vertically; five albums display as horizontal square cards.
See all reuses each loaded model and real cursor; further pages load explicitly.
A cold instantiated active section makes one page read; a retained loaded/empty
section makes zero on reentry. New's explicit Refresh refreshes both sections;
individual Retry/See all Refresh/Load more affects only that section. Independent
owned tasks prevent a stalled track section from gating albums. Off-tab and
covered New destinations cancel their task ownership. A push during a refresh
may cancel it and retain prior data; explicit Refresh remains available.

Artwork presentation accepts a size parameter (52points remains the default;
New album cards use144). The160px request and ownership policy are unchanged.
This may soften thumbnails on high-density screens; no larger image requests
were introduced in this isolated step. Pin/favorite errors remain local.

## Frozen boundary and simplification audit

FoundationPlayer.swift, FoundationCredentials.swift, playbackURL and the entire
native send/session implementation match the accepted base byte-for-byte.
Existing shared catalog row/destination visibility changed from private to
internal for reuse; no copies of the old controllers were imported. Home/Search
remain inactive. Shared UI reuse avoids new playback/menu/queue code. Production
lines increase to restore the feature; deletion is not a quota.

## Verification and limitations

Repository lint/diff and macOS compile pass; all53 synthetic tests pass. New
coverage proves recent query limits/sort/type/cursor, no automatic retry, stalled
tracks with independent successful albums, cancelled late result suppression,
shared loaded/empty page retention, and explicit cursor paging. Existing player
and duplicate occurrence tests remain green. The initial type-name collision
was corrected before the passing compile. Existing nativeLoad Sendable warnings
remain unchanged within the freeze.

Independent source review found no blocking issue and requested a local pin
error display, which root added. Exact signed artifact records contain final
Release/exclusion/signing/install results. These gates are not touch/pointer or
private-network acceptance. Owner tests the exact candidate next.

The original Home shell was visible in the legacy simulator; its New tab could
not be opened through the UI tool because it returned noWindowsAvailable. The
New layout was therefore checked against the original HomeView.New presentation
source (six vertical tracks/five album shelf), not claimed as live New-tab VQA.
