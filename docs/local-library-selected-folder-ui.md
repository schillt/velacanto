# Selected-folder presentation for #112

Source-only implementation on 2026-10-26, based on exact local main
`f822df6be2885bc2867ba1e19747a67153c9fac8`, branch
`codex/local-folder-ui-112`, isolated worktree `release060-local-folder-ui-112`.
Live GitHub #112/#115 and their latest comments were read using the Personal
connection. Both remain open in v0.6; this slice does not complete either issue.

## Implemented scope

`FoundationLocalLibraryModel` is an app-owned observable facade around the existing
selected-source actor. Its cache-only restoration runs in a separate SwiftUI task;
server readiness and audio never await it. Sign-out does not retire or clear this
owner. The optional environment defaults to nil for existing fixtures. No new
local state is injected into account, Jellyfin, cloud, player, Handoff or queue
owners. Library itself still requires the existing signed-in shell; independent
local-only launch/navigation is not implemented by this narrow sheet entry.

Library exposes a dedicated native Local Library sheet: a sidebar-header button
on macOS and a Library toolbar button on iOS/iPadOS. `fileImporter(.folder)` receives
an explicit grant; the facade balances that grant around bookmark creation by
the existing actor. Choose Folder saves authorization only. Refresh Index is a
separate, explicit action; startup, sheet appearance and reselection never scan
or retry automatically. Cached restoration requires no selected-folder access.
The source actor continues to own bookmark validation and scoped refresh access.

The sheet presents bounded index records by source-scoped identity, file-derived
title, byte count and missing-at-last-complete-refresh status. It distinguishes
loading, no selection, empty, partial, unavailable, corrupt cache and authorization
restoration failure, and offers explicit reselect/refresh recovery. Loading can
be cancelled; cancelled restoration exposes an explicit Load Saved Index action
without claiming the saved selection is absent. Revision tickets and task cancellation prevent late operations from
publishing after cancellation/Forget. No index record is converted to a Jellyfin
item or passed to a server route. There are no Play, Favorite, playlist or Download
actions, network artwork, cloud file download requests or music-file writes.

Forget Folder requires a native confirmation explaining its limited semantics:
remove the saved authorization manifest and hide/retire displayed records; never
delete music; old private index snapshots and backups are not erased. A removal
failure retains the selection and reports an error. Reselection gets a fresh
source ID under the existing actor contract. Paths/bookmark bytes and raw errors
never enter diagnostics, server requests or cloud payloads. File-derived titles
are shown only in this local sheet. Private index/manifest retention and protection
limits in `local-catalog-composition.md` remain applicable.

## Proposed macOS entitlement change — NOT applied

The existing sandbox lacks selected-folder access and app-scoped persistent
bookmarks. Root owns reviewing/applying this exact additive diff and verifying
actual signed canonical/local identities. No signing, team, profile, App ID,
Keychain, broad exception or entitlement change was made by this worker.

```diff
--- a/NativeFoundation/Resources/Velacanto-macOS.entitlements
+++ b/NativeFoundation/Resources/Velacanto-macOS.entitlements
@@
 <key>com.apple.security.network.client</key><true/>
+<key>com.apple.security.files.user-selected.read-only</key><true/>
+<key>com.apple.security.files.bookmarks.app-scope</key><true/>
 <key>com.apple.application-identifier</key><string>$(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)</string>
```

Native bookmark creation, signed sandbox access, relaunch restoration and platform
picker behavior remain unverified. Until the entitlement review and signed gates
pass, macOS folder selection/refresh may fail closed; source wiring is not proof
of functional native access. No claim of read-write filesystem entitlement is made.

## Verification and limits

- Focused strict swift-format lint passes for the two new source files and test
  file; whitespace diff check and PBX plist validation pass.
- `scripts/preflight.sh --skip-xcode`: zero failures, five environment warnings
  (disk space, unset Git author name/email, no installed signing identity, explicitly
  skipped Xcode checks). No source capability change follows from that inventory.
- Whole-repository `scripts/build.sh lint` fails on existing findings solely in
  unchanged FoundationLibraryActions and FoundationPinSync source/test files;
  no new-file or changed UI/app-file findings remain. No baseline was expanded.
- Eight new deterministic facade tests are written and registered, but UNRUN:
  cache-only restoration without account/scan; cancelled restoration with explicit
  reload; cached-record retention on explicit
  unavailable refresh; corrupt-cache versus empty/partial states; successful late
  scan rejection on cancel; late scan rejection after Forget with music preserved;
  explicit corrupt-authorization recovery; failed Forget retaining visible state.
- No Xcode build/test, simulator/native UI run, device action, signing/capability
  registration, install, server mutation, distribution or publication was performed.
  The existing source actor's ten tests remain unrun by this worker as well.
- Required follow-up: compile/test both platforms serially, native iPhone/iPad-width/
  macOS sheet/accessibility evidence, actual selected-folder bookmark/relaunch,
  moved/missing/unavailable/cloud-only-file behavior and data-retention checks.

#115 still owns actual catalog composition, shared source/item identity and local
playback resource leases across queue/item lifetimes. Indexing's short access scope
is not a playback lease. This index-only sheet cannot establish usable local music
playback or final shipping readiness. Keep #112/#115 open and do not ship the final
feature until #115 and the remaining native/physical acceptance gates are complete.
Installed iPhone diagnostic222 and Mac219 are unchanged; no installation or acceptance
is implied by this implementation.
