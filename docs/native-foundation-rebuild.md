# Foundation rebuild: current delivery guidance

Owner direction recorded2026-09-05. See ADR0012, umbrella#65 and Library#105.

## Preserved architecture and evidence

Native Apple playback/networking, a shared core, provider-neutral product models,
and source adapters remain the accepted direction. Jellyfin is the only current
server implementation. Keep provider details inside its boundary; do not create
speculative plugin infrastructure. Original app screens are design references,
not permission to reintroduce legacy controllers or recovery code.

Minimal baseline user tests succeeded on rapid skips, Previous, direct queue
selection and album switching. Subsequent UI candidates were tested incrementally.
No broad recovery percentage or first-stall root cause is established. The
Jellyfin media route and workload also changed during the rebuild.

## Frozen boundary

The latest local combined source baseline is cc41d4a01b304344fa1a7f119b20974a9a5de962.
FoundationPlayer, playbackURL stream policy, native session configuration,
audio-session behavior and credential security are frozen during UI restoration.
The exact worker base is assigned by the coordinator. These local commits are
not represented as already published on GitHub or as accepted release candidates.
Do not merge the accumulated local legacy history wholesale to publish them.
Source publication must identify the reviewed diff and exact candidate separately.

## Current parallel work

- #135: Genres, bounded catalog hooks and explicit favorite API.
- #136: Source-scoped pin/unpin and equivalent visible/touch/pointer menus.
- #137: Native macOS shell and Library acceptance.

Workers use one isolated local tree per task, non-conflicting owned paths,
proactive exact handoffs, local commits only, and root-granted serial Xcode slots.
The coordinator integrates serially and automatically installs ready signed
builds on the authorized test phone. The owner tests one candidate at a time.
Both macOS compilation/native interaction and iPhone testing remain required.

## Next Library acceptance

Genres to albums/tracks; local persistent account-scoped pin/unpin; explicit
favorite/unfavorite; visible menus as well as long press and secondary click;
existing albums/artists/songs/playlists/favorites; navigation while playing.
Pin operations make zero network requests. Server mutation is one explicit
request without automatic retry; errors remain local and honest.

Advanced queue mutation, Play Next, shuffle/repeat, playlist editing, new
providers and local indexing need separate approved scope where they touch
frozen behavior. Do not simulate these by restarting the current queue.
Home/New/Search feature work can be prepared later but is not a reason to delay
Library acceptance or add hidden loads now.

## Gates and GitHub status

Run lint/diff and focused tests per task, combined deterministic tests, iOS Debug
signing/Release exclusion, and macOS compilation at integration. Detailed journal
and fault injection remain absent Release. Record real device limitations.
Preserve prior issue history and old build artifacts; do not label legacy issues
fixed merely because a replacement UI works. Documentation publication is not
source integration, hosted-quality acceptance or device/release acceptance.
Promotion remains alpha → beta → preview → main. Earlier target dates are
historical, not evidence of completion. No new milestone dates are invented.
