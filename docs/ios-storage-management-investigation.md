# iPhone Settings storage management — v0.6 investigation

Tracked in [#208](https://github.com/schillt/velacanto/issues/208), alongside #13.
General native HLS download shipping remains post-1.0 under #189; a disposable
Settings API proof does not silently promote that separate contract.

Owner requirement, 2026-10-25: retain useful download actions/status on music
surfaces, but remove bulk downloaded-music management from Profile. Target the
storage-management style in iPhone Settings: sizes and removal of retained music,
not an embedded live transfer/progress interface. An in-app-only substitute has
not been accepted as fulfilling that target.

## What is established

Apple Music supports editing downloaded songs/artists through Settings → Apps →
Music → Downloaded Music. Apple's [iPhone Music guide](https://support.apple.com/guide/iphone/add-music-and-listen-offline-iph0cff2d191/ios)
documents this. The feature's existence is not in dispute.

Apple also documents [iPhone Storage](https://support.apple.com/en-us/108429):
Settings → General → iPhone Storage → an app reports storage, supports offload/
delete, and may allow some documents/data to be deleted depending on the app.
This is a distinct system surface from an app's ordinary Settings.bundle pane.

The public [Settings.bundle interface](https://developer.apple.com/documentation/foundation/building-a-settings-bundle-for-your-app)
defines preference elements, including groups, toggles, values and child panes.
Current VelaCanto already puts streaming/download quality and cellular preferences
there. This schema alone does not establish a music-aware deletion/provider API.

**A documented public candidate exists:** Apple's [WWDC20 offline HLS session,
storage management at 15:51](https://developer.apple.com/videos/play/wwdc2020/10655/)
explains that `AVAssetDownloadStorageManager` policies let users delete downloaded
HLS assets through Settings, with the download task's title/artwork. Assets must
remain at their system-provided locations and the app must handle their removal.
This establishes a supported route to prototype, rather than an unknown API.
It does not establish that existing arbitrary audio files can be registered, or
that the resulting screen matches Music's artist/album hierarchy.

[UIFileSharingEnabled](https://developer.apple.com/documentation/bundleresources/information-property-list/uifilesharingenabled)
exposes the app's Documents files for sharing. Together with
[LSSupportsOpeningDocumentsInPlace](https://developer.apple.com/documentation/bundleresources/information-property-list/lssupportsopeningdocumentsinplace)
it exposes Documents through Files/document-browser access. Those documented
behaviors are not proof of Apple Music's artist/album storage interface. Apple's
[storage guidance](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively)
reserves Documents for user-visible files and Application Support for internal
support records. A public filesystem switch must not be treated as a harmless
way to expose all of VelaCanto's private download metadata.

`NSSupportsPurgeableLocalStorage` is also not an established solution for this
requirement. Apple's [Shared iPad guidance](https://developer.apple.com/education/shared-ipad/)
and [archived Cocoa key reference](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CocoaKeys.html)
describe allowing the local container to be purged at system discretion when a
Shared iPad user signs out, with durable content restored from cloud/services.
That is not a documented song/album deletion provider for iPhone Settings. Do
not opt VelaCanto's retained local state into that policy as a storage-UI shortcut.

## Current VelaCanto boundary

- `FoundationDownloadStorage.base` is an Application Support download root with
  opaque account-scoped subdirectories. It is not a public Documents library.
- `FoundationDownloadTransport` uses an ephemeral `URLSession.download(for:)`;
  Original files and converted AAC/M4A files use the existing verified-file path.
  They are not offline HLS assets produced by `AVAssetDownloadURLSession`.
- The manifest stores retained owners, repeated collection members, exclusions,
  verification data, requested quality and cached catalog/artwork metadata.
  Audio files can be shared by multiple download owners.
- `FoundationDownloads` owns storage totals, reconciliation, removal and
  playback-resource leases. A currently playing file is removed only after its
  playback owner releases it. Sign-out/reauthentication have separate privacy
  lifetimes; exposing raw files can bypass those intended boundaries.
- `FoundationSettingsView` currently links bulk Downloaded Music from Profile.
  `FoundationDownloadManagementView` implements storage totals, song/collection
  selection and removal. Per-item menus are separate and must remain usable.
- No File Provider/storage-management extension is implemented in current source.
  No storage exposure or migration switch has been enabled by this investigation.

## Next bounded proof

1. Prototype the documented offline HLS/`AVAssetDownloadStorageManager` route in
   a disposable synthetic identity. Check current SDK availability, actual
   Settings listing/deletion and app reconciliation before changing production
   storage. Avoid private Settings plugins or undocumented preference URLs.
2. Determine whether Jellyfin can supply a finite, authenticated offline HLS
   asset that preserves each requested quality, including Original. Compare the
   new system-managed package lifecycle with existing verified-file downloads;
   do not silently replace accepted Original/converted behavior or move existing
   files into a speculative registration scheme. Keep document-based exposure
   separate; a Files listing alone does not satisfy the requirement.
3. Keep manifests, credentials, personal account metadata and internal paths
   private. Define how external deletion reaches the existing download owner,
   preserves shared retention/playing-file safety, rejects stale scopes and
   updates offline availability without re-downloading a deliberate removal.
4. Verify upgrade/rollback, cold relaunch, deletion while suspended/playing,
   account replacement and failed reconciliation. Record real-device system
   storage evidence separately from Simulator behavior.
5. Remove the Profile bulk entry only after an accepted replacement path exists;
   keep in-app per-item download/remove/status functionality. If the requested
   system integration cannot be supported safely, report the exact limitation
   and obtain an owner decision on the fallback rather than silently relocating
   the same Profile screen elsewhere.

Status: a documented third-party offline-HLS Settings removal route is identified;
its integration with VelaCanto's current downloads remains unverified.
No claim that a plist flag can reproduce Music's controls, and no blanket claim
that all system storage integration is impossible. No runtime/storage migration,
physical deletion, server mutation or Profile UI removal has occurred.
