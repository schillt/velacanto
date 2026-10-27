# VelaCanto

VelaCanto is a native Jellyfin music app for iPhone, iPad and Mac. Development is
working toward **0.6**, including shared iOS/macOS feature parity, playlist and
CarPlay refinement, native continuity, consistent UI/loading and maintainability.

The current local alpha checkpoint is **0.6.0 (233)**, signed and installed on Mac
and iPhone, with runtime source published in `5718da7`. Read the
[checkpoint](docs/0.6.0-alpha-checkpoint.md) for verification limits and the
[30-issue status matrix](docs/0.6.0-issue-status.md) for remaining work. Native UI
failures/skips remain open; this is not a completed0.6 release or TestFlight
availability record.

Use the [live milestone](https://github.com/schillt/velacanto/milestone/9),
[current agent handoff](docs/0.6.0-agent-handoff.md), and [instructions](AGENTS.md)
for current scope. Older release documents retain evidence for their own builds.
The product spelling is **VelaCanto**; legal publisher drafts use **NovoLuxor**.

## Current experience

- Browse Home, New, Library and metadata-aware Search, with favorites, local pins,
  artist suggestions, album artwork and multi-disc track headings.
- Play songs, albums and playlists through HLS; use Play Next/Last, shuffle/repeat,
  editable phone/Mac queues, synchronized lyrics, native AirPlay and system playback
  controls. Queue restoration is paused; saved playback position is not restored.
- Browse native CarPlay Home, New and Library, start music and view Up Next.
  CarPlay permits viewing/skipping within the queue; editing stays on phone/Mac.
- Create playlists, optionally add songs immediately, search/select multiple songs,
  and manage playlist membership with native platform controls and contextual actions.
  Removing a playlist entry does not delete its source song.
- Download Original files or AAC quality presets for offline listening, with
  progress, cancellation, retry and account-owned storage. Existing ready downloads
  are reused when preferences change. Downloaded playlists reconcile on scoped
  lifecycle/edit triggers and retain usable content on refresh failure.

On iOS, system **Settings → VelaCanto** contains separate Wi-Fi/wired and cellular
streaming profiles: Original, Auto and AAC ceilings of 320/192/128 kbps. Auto can
choose Original on suitable unmetered Wi-Fi/wired paths; it uses connection policy,
not a measured-bandwidth adaptive ladder. Downloads have a separate quality choice.
New selections apply to newly prepared streams/downloads. Mac streaming uses
Original and does not expose quality selectors. Original preserves compatible
source encoding; unsupported formats may require server conversion.

Basic Siri/system media commands are supported. This release makes no Apple
Intelligence, natural-language catalog playback or on-device AI claim. Lyrics,
recommendations, permissions and transcoding depend on the server/library. Jellyfin
is the only implemented provider. Pins are local per installation; favorites are
server-backed. Native HLS offline downloads are not implemented: converted downloads
are verified AAC/M4A files, distinct from HLS streaming.

Mac credentials now use the Data Protection Keychain. The first upgrade can require
a fresh sign-in; legacy credential items are never read, migrated or deleted. Local
account data is held pending authenticated recovery, with an explicit confirmation
if no exact saved account scope matches. Keep the same server address/account when
recovering an existing installation.

For the previous accepted scope, read [release notes](docs/0.5.0-release-notes.md),
[TestFlight testing notes](docs/0.5.0-testflight-notes.md) and
[acceptance and deferred work](docs/0.5.0-acceptance.md) for that version’s supported scope and limits.

## Branches and distribution

| Branch | Purpose / recorded checkpoint |
| --- | --- |
| `alpha` | Permanent development branch; initial integration base `bf1af68`. See the current checkpoint for publication status. |
| `beta` | Permanent validation branch; v0.5 merged through PR #205 at8d69179. |
| `main` | Previously accepted preview promoted through PR #190; not automatically advanced with alpha. |

“Alpha Preview” describes this release's maturity; it does not create or promote a
`preview` branch. Historical branches/tags remain evidence. Develop locally, publish
accepted changes to alpha, and authorize beta/main promotion separately. See
[development workflow](docs/development-workflow.md).

Never delete alpha, beta or main after promotion. All task/worktree refs, including
codex/*, stay local. Verify permanent branch heads before/after authorized promotion.

Automatic TestFlight delivery is reserved for `main`. An owner-started manual
TestFlight push is a separate action; do not remove its Cloud post-actions or
promote branches merely to make that push possible. GitHub quality results and
Apple processing/availability remain separate records.

## Development

Open `NativeFoundation/VelacantoFoundation.xcodeproj`, scheme
`VelacantoFoundation`. Internal targets/executable names and bundle/storage
identities remain unchanged; the canonical bundle is
`com.chameleonenterprise.velacanto`. No legacy app target remains.

```sh
./scripts/preflight.sh --skip-xcode
./scripts/build.sh all
# Select an existing authorized OS 27 simulator before tests:
# export VELACANTO_IOS_SIMULATOR_DESTINATION='platform=iOS Simulator,id=<authorized-UUID>'
./scripts/build.sh pr
```

Modes: `lint`, `macos`, `test`, `ios-simulator`, `ios-simulator-test`, `release`.
Builds use per-worktree derived data. Set `VELACANTO_PACKAGES_PATH` for an existing
package cache. The committed SwiftPM resolution is required. App and tests require
iOS/iPadOS 27 and macOS 27. Use Xcode 27 or newer; scripts honor an explicit
`DEVELOPER_DIR` and do not automatically select a beta toolchain. Warnings remain
errors; the historical lint baseline is not permission to introduce findings.

Only playback and Now Playing receive priority. Browsing publishes independently;
optional content must never gate audio. Read the
[playback protection contract](docs/playback-protection.md) before shared async work.
Unsigned builds and simulator results do not establish audibility, signed
provisioning, accessibility or Apple distribution acceptance.

## Release and architecture references

- [0.5.0 acceptance and deferred work](docs/0.5.0-acceptance.md)
- [0.5.0 release notes](docs/0.5.0-release-notes.md)
- [0.5.0 TestFlight notes](docs/0.5.0-testflight-notes.md)
- [Historical 0.4 development record](docs/0.4-development-record.md)
- [Historical 0.3.5 acceptance](docs/0.3.5-acceptance.md)
- [Architecture](docs/architecture.md)
- [Dependencies and notices](docs/0.3-dependencies.md)
- [Publication safety](docs/publication-safety.md)
- [Agent instructions](AGENTS.md)

Media URLs can contain authentication tokens. HTTPS protects transit, but does not
prevent exposure in server/proxy logs or endpoint retention; the conditional URL-token
privacy investigation remains deferred. No release claim here establishes its
remediation. Credentials, signing material and raw traces never belong in source.

Publisher: Chameleon Enterprise Ltd. VelaCanto is public-source proprietary
software under its [LICENSE](LICENSE), independent of and not endorsed by Jellyfin.
