# VelaCanto agent instructions

## Current authority

Current owner instructions and the live GitHub issue contracts govern the work.
The [0.6 milestone](https://github.com/schillt/velacanto/milestone/9) is the delivery
scope source of truth. Read each issue and its latest relevant comments before
changing it. This guide replaces the preceding agent guides at the owner's
request; older release records remain historical evidence, not current commands.

The maintained app is `NativeFoundation/VelacantoFoundation.xcodeproj`, scheme
`VelacantoFoundation`. Product spelling is **VelaCanto**. Preserve internal bundle,
Keychain, storage and target identities. Local builds may display VelaCanto Alpha;
canonical distribution naming remains VelaCanto. Publisher documentation uses
**NovoLuxor**, `support@novoluxor.dev`, United States. Privacy and terms remain drafts.

Read [the current checkpoint](docs/0.6.0-alpha-checkpoint.md),
[the agent handoff](docs/0.6.0-agent-handoff.md), and the nested app guide first.
Build233 source, signing, installation and verification limits are recorded in
the checkpoint and relative-path runtime manifest. A source tree or green unit gate
alone does not establish physical acceptance or distribution readiness.

## Branches and publication

Preserve GitHub `alpha`, `beta` and `main`. Never delete, rename, replace,
force-push or rewrite them. Task branches and worktrees remain local; do not
publish `codex/*` or other temporary branch refs.

The owner authorized one reviewed usable stopping-point integration to GitHub
`alpha`, after installing that exact build on the Mac and iPhone and including
current documentation and handoff reports. This is not standing permission for
future publication, beta/main promotion, tags, releases, TestFlight or App Store
submission. Revalidate current alpha before a normal non-force publication and
preserve beta/main heads. Stop on a protection rejection; do not weaken a rule or
publish a task branch as a workaround.

Before any actual release/promotion/distribution, audit every page of the live
milestone. Each item needs completed acceptance, explicit later-milestone
replanning, or an owner-approved discarded disposition. Do not close issues,
defer scope or mark checks passed merely to clear the gate. Development alpha
source publication is not that release disposition.

## Work and verification

Keep all new source, build output and detailed evidence on non-synchronized local
disk. Do not write development work into iCloud. Preserve historical archives and
dirty work; do not repair or replace an older checkout to simplify integration.

Parallel bounded agents are authorized. Give each distinct topic clear file
ownership and a separate local working copy. Do not edit another worker's files.
Integrate serially and review the actual combined diff. A single coordinator owns
the Xcode/simulator/device lane; read-only review and source work can run alongside
it. Use existing authorized simulators/devices; preserve app identities and data.

Run proportionate tests for changed behavior, then combined iOS/macOS and signed
package checks for the frozen build. Preserve failed logs and diagnose them before
rerunning. Poll the same live process handle; a timeout is not completion. Do not
relax assertions, add arbitrary sleeps, bypass privacy protection, or count skipped
or inconclusive UI checks as accepted. Avoid automatic failure diagnostics when
explicit bounded evidence already covers the failure. Report actual scope and
counts, including platform differences, pending native checks and limitations.

## Runtime and privacy invariants

Use the existing player, queue, native activation and continuation owners. Audio
and Now Playing remain independent of optional browsing and artwork. Only actual
playback/Now Playing work receives preferential admission; ordinary browsing stays
bounded and independently published. Preserve cancellation, account retirement,
occurrence identity and rejection of stale callbacks. Read the existing
[playback protection contract](docs/playback-protection.md).

Keep original view appearance and native underlap. Expanded navigation clearance
belongs at the end of scroll content, not in an opaque overlay or clipped viewport.
Related Now Playing sheets must respect system appearance and their context.

Continue Listening is remote-only: reuse its media card for another device's
track, artist, album, artwork and reported progress. No local resume fallback or
Now Playing duplication. Dismissal hides the card without stopping playback; use
native accessible trash/swipe controls. Browser continuation is separate pending
work; do not show Apple Handoff instructions for clients that cannot use it.

The owner selected best-effort automatic stopping for browser/other-client
continuation: only after actual receiver start, recheck the original session and
send one stop if it still matches. Report unsupported, changed or unconfirmed
source control honestly. Preserve reported queue order/duplicate occurrences;
never claim unavailable original shuffle state, silently truncate, or transfer
credentials. Keep the stronger native Handoff safeguards intact.

Validate server/user/source ownership and server permissions before async results
or mutations. Do not weaken file protection to make tests pass. No new player,
retry/polling/watchdog framework, hidden whole-catalog scan or unrelated provider.
The optional pin-sync configuration remains off; no Cloud container/capability or
workflow change is implied.

The repository is public. Stage explicit reviewed paths, never broad `git add .`
or `git add -A`. Keep credentials, private server/media/account/device details,
profiles, signed apps, raw traces, receipts, local inventories, generated Xcode
state and Cloud registration manifests out of commits. Legal drafts are not
effective agreements. Read `SECURITY.md` and `docs/publication-safety.md`.

Every handoff names the exact base/final source, changed paths, tests, integration
state, privacy review, known gaps and next owner. Distinguish implemented, tested,
installed, published, accepted and distributed.
