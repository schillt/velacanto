# VelaCanto

VelaCanto is a native Jellyfin music app for iPhone, iPad and Mac.
Active development is **0.7.0**, focused on reliability, privacy, measured
performance and platform polish while preserving the accepted 0.6 experience.

Start with the [0.7.0 agent handoff](docs/0.7.0-agent-handoff.md),
[live milestone](https://github.com/schillt/velacanto/milestone/7),
[roadmap](docs/roadmap.md) and [instructions](AGENTS.md). The previous development
baseline is **0.6.0 (309)**; its exact checks remain in the
[historical checkpoint](docs/0.6.0-alpha-checkpoint.md). Production pin sync is
owner accepted as of November 2, 2026; residual iCloud lag is an accepted limitation.
The local source is labeled **0.7.0 (322)** for a separate review candidate.
Earlier build321 owner acceptance remains scoped to its recorded Mac/iPhone checks;
current artifact, signing and installation status are recorded in the handoff.
Local implementation remains unpublished; installed review, source publication
and distribution are separate states.

The product spelling is **VelaCanto**; publisher drafts use **NovoLuxor**.

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
is the only implemented provider. Pins remain local unless optional iCloud sync is enabled; favorites are server-backed.

Library Artists and artist Search use the same Jellyfin album-artist index. An
artist credited only on standalone tracks may be absent from these artist results
if the provider does not include that identity in its album-artist index. A missing
or zero album count does not establish standalone status, and performer credits do
not reliably distinguish primary artists from featured contributors. For 0.7,
the owner accepted this documented provider limitation under
[#157](https://github.com/schillt/velacanto/issues/157). Standalone-artist
supplementation remains unsupported; the app does not infer it from names/counts
or scan the catalog to classify artists.
See the [provider audit and bounded request budget](docs/standalone-artists-157-provider-audit.json).

The optional native system-managed download route has scoped AAC acceptance and
Apple-managed media labels; broader format/storage-pressure coverage remains open.
Original/AAC file downloads remain distinct from online HLS streaming.

For **0.7**, native system-managed HLS downloads have no demonstrated enforceable
in-flight byte cap. An oversized download can consume storage before it finishes;
a completed-package size check is not a limit during acquisition. Check free
device space before downloading. A lower AAC download preset can reduce expected
storage use, but it does not guarantee a maximum total size. Cancel unwanted
requests and remove completed downloads through **Downloads → Manage Downloads**
or the iPhone's system Storage controls. Original downloads remain app-managed.
If an Original request fails with system management enabled, remove that failed
request, turn off **Manage New Downloads in iPhone Storage**, then request it again.
Changing preferences does not replace existing ready downloads.

The owner accepted this limitation for 0.7. Physical native
selected-quality, storage-pressure, cancellation, restart and deletion/account
reconciliation validation remains pending or requires explicit owner disposition
under [#214](https://github.com/schillt/velacanto/issues/214). Existing scoped
AAC/offline/system Storage acceptance is preserved; this disclosure is not a new
native validation pass.

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
| `alpha` | Permanent development branch; accepted 0.6 baseline plus current 0.7 preparation. Resolve the live head before work. |
| `beta` | Permanent validation branch; recorded 0.5 candidate `192ab0c`. |
| `main` | Older 0.5 candidate promoted through PR #217 at `e45a190`; not automatically advanced with alpha. |

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

- [Current 0.7.0 handoff](docs/0.7.0-agent-handoff.md)
- [Historical 0.6.0 checkpoint](docs/0.6.0-alpha-checkpoint.md)

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
prevent exposure in server/proxy logs or endpoint retention. Playback/download
URL-token privacy remains unremediated under #25; the owner deferred unfinished
work to **0.9.0** on November 12, 2026. Preserve operational redaction and retention
guidance; isolated relay experiments do not establish remediation in the installed
app. Credentials, signing material and raw traces never belong in source.

Publisher: Chameleon Enterprise Ltd. VelaCanto is public-source proprietary
software under its [LICENSE](LICENSE), independent of and not endorsed by Jellyfin.
