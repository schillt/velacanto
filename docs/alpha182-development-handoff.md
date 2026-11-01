# Alpha182 development handoff

Owner-authorized alpha publication, 2026-10-14. Next owner: development chat and
workspace maintainer. No separate issue or promotion PR was created for this
publication.

## Start from GitHub alpha

Fetch `origin/alpha` before further implementation. Read the fetched root
[AGENTS.md](../AGENTS.md), [NativeFoundation/AGENTS.md](../NativeFoundation/AGENTS.md),
[playback protection contract](playback-protection.md), and
[development record](0.4-development-record.md). Compare applicable issue contracts
and current owner instructions. Create a clean local task worktree from current
alpha; preserve dirty and unpublished work in older worktrees. Do not replace
their instructions or cherry-pick already-integrated changes based only on local
commit IDs.

## Published checkpoint and provenance

- Integrated source: `90ee2e3daf047a07927af6ad895070d135df637a` on GitHub alpha.
- Published parent: `0819dba195521a3efdd194afa04cd95350ee3897` (existing beta history).
- Exact accepted local source: `87366951e9c34b852e0d359a453180c81ea3f21c`.
- Both source trees: `5cf04ab8d184d04465a4b0486f92aea94ff5b954`.
- Playback patch: `46aefa920cb749d2446fb83889ffca6c15f2914b`, based on
  Alpha181 `0ae4c772250979eb685238d09b635c2e3f49a6a1`.
- Signed Alpha182 source: `b38b8bd`; later local changes document installation,
  initial owner acceptance and guardrails. This handoff changes documentation only.

Alpha was absent on GitHub. The authenticated connector created an integration
commit because command-line Git had no usable authentication. All 64 uploaded
file hashes and the full tree were verified against the local candidate; fetching
the new alpha confirmed identical content. Local commits and worktrees remain
preserved. Local-only commit IDs above are provenance, not necessarily GitHub
commit links. Publication includes accumulated build124-to-182 development
(search, CarPlay, pins, duplicate filtering, artist presentation and playback),
not just the latest playback patch. Beta and main were not moved.

## Guardrails for ongoing work

Only playback and Now Playing receive preferential admission. Artist, Album,
Home, New, Library, Search, playlists and related browsing remain equal and
publish completed sections independently. Native audio, controls and session
activation must never wait on optional artwork or catalog admission. Explicit
collection Play resolution is protected; ordinary queue additions are not.

Preserve bounded protected worker and pending-request capacity, promotion of
coalesced requests, cancellation cleanup, account retirement and stale-state
rejection. Artwork stays optional: retain usable sharp images, prevent same-item
quality downgrades, reset on identity changes and use scoped recovery boundaries.
Do not add speculative automatic retries, transport replacement, cache purges or
global serialization to hide a stall.

Shared loader/cache/presentation changes require playback review even if player
files are untouched. Follow the contract's regression and physical acceptance
matrix. Silent playback with persistent loading is a P1 acceptance blocker.

## Evidence and remaining gates

Existing evidence: 508 Mac tests and 257 affected iOS tests passed; Release builds
and identity/privacy/diagnostic checks passed. Signed Alpha182 was installed on
the existing Mac Alpha identity and authorized iPhone13mini, preserving data.
The owner reported that the build passed initial testing. No new runtime tests
were needed for publication or this documentation follow-up.

This does not prove the original silent-spinner cause or an exhaustive matrix.
Detailed sustained playback under browsing load, background/queue, seek/skip and
route coverage remains pending where not separately recorded. Real-vehicle
CarPlay acceptance remains pending. Keep those limitations visible.

Independent bounded publication review covered 165 local commits, 65 historical
paths and 64 final changed text files: no publication blockers or secrets found
in that reviewed scope. No signed apps, private logs or device artifacts were
published. This was not an exhaustive historical security audit.

Continue local development and publish accepted integrations to alpha. Hosted
release gates, alpha-to-beta promotion, main, tags and TestFlight retain their
separate owner authorization and acceptance requirements. Do not treat this
alpha publication as a release decision.
