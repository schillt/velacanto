# Local source dependency and catalog composition

Source inspection and live #112/#115 contracts: 2026-10-26. Local base
`2ac8539` includes the read-only index, not a verified end-to-end local provider.
This document records implementation boundaries and remaining decisions; neither
issue is complete.

## Selected folder ownership added for #112

`FoundationLocalSource` owns one selected source, its versioned bookmark manifest,
explicit refresh and retirement independently of Jellyfin session/sign-out state.
The native bookmark adapter remains read-only, rejects stale/unavailable grants,
balances access around index refresh, and never falls back to a remembered path.
Cached results require no folder access. Corrupt manifest restoration throws rather
than pretending no source was configured. Refresh failure preserves cached records
with unavailable source state. Selection/reselection receives a fresh source UUID;
late retired work cannot publish into that selection. Caller cancellation cancels
its scan task and cannot publish successful late results. No automatic scan/retry
is introduced.

The manifest and cached index contain private authorization/metadata. They belong
in private app-owned storage outside the chosen music folder, never in shared
settings, continuity payloads, diagnostics, issues or release artifacts. The
selected-source owner reuses the index canonical/resource-identity containment check before bookmark creation and again
before creating storage and writing the manifest. This rejects case-equivalent
and symlink aliases; it does not claim descriptor-relative protection against
concurrent filesystem changes. Atomic complete-protection writes and size bounds
do not establish backup exclusion or application-layer encryption. Removing selection removes its authorization
manifest; old per-source index snapshots remain private on disk and are not
returned for a new selection. A future Forget Library flow must explicitly own
cache erasure and its failure outcome before claiming local-data deletion.

Ten focused tests cover persisted identity, new-source reselection/removal,
unavailable authorization, corruption, storage containment, late retired results,
caller cancellation, case-equivalent and symlink storage aliases, and revalidation
after bookmark creation. Synthetic authorization is not a native picker/bookmark
or signed sandbox test. No platform tests have been run by this worker.

## Minimal integration proposal requiring shared-path ownership

The existing `FoundationItem.id` is opaque only within the account-owned library.
`FoundationItemReference`, artwork cache keys, pin state, collection expansion,
queue persistence, reporting, and Handoff currently inherit that source scope.
A local path or local UUID must never be sent to the Jellyfin adapter as an item ID.

Before changing those owners, introduce one explicit source-scoped presentation
reference containing source kind (only Jellyfin or local), stable source identity,
opaque item identity, and honest capabilities. Keep provider item IDs unchanged
inside the adapter. Existing Jellyfin-only persisted items need a documented
account-scoped decoding default; unknown/retired sources must fail closed.
References, navigation keys, selection keys and artwork namespaces must all use
that source-scoped reference, including related album/artist routes. Capabilities
must distinguish local read-only catalog presence from supported playback and
server mutations. A local entry initially has no favorite, playlist mutation,
Jellyfin download, reporting or artwork-network affordance.

Source owners publish bounded pages independently. Keep separate local and server
load/empty/error/partial states and continuation positions. A delayed/error server
must not hold local publication, and local indexing must not hold server results.
Use stable source order plus existing per-source order; continuation/identity
validation belongs to each source. No await-both publication barrier, global
scheduler, browsing priority hierarchy, generic plug-in registry or new player is
needed. This is a proposed shared seam, not implemented composition.

## Remaining end-to-end dependencies

- A native folder picker and observable local-source presentation owner must wire
  the new actor to private storage and explicit select/refresh/remove actions.
- macOS needs a reviewed user-selected read-only sandbox entitlement. Validate
  actual signed canonical/local identities and native bookmark relaunch behavior;
  this worker has made no entitlement or signing changes.
- App startup/sign-out must keep local authorization/index lifetime independent of
  Jellyfin, without disclosing private metadata in a different source scope.
- Local playback needs an existing-player resource lease that retains security
  scope through native item use and releases it on replacement/failure/retirement.
  Indexing's short access closure is not a playback lease. Resolve queue restore,
  missing/moved files, source removal and Handoff eligibility before enabling Play.
- #112 needs focused platform tests and real selected-folder lifecycle acceptance.
  #115 remains dependent on that verified provider and then needs actual combined
  browse/search/detail wiring, bounded page tests and local/server acceptance.

The owner's current full v0.6 development authorization permits this dependency
work; historical freeze text does not create another automatic approval step.
Actual shared player/transport changes still need their narrow rationale, root
path ownership, regression gates and physical playback acceptance under the
standing playback-protection contract. No integration, publication, release,
installation or issue closure follows from this isolated implementation.

## Binding and presentation lifetime

The concrete `FoundationCatalogFetchBinding` captures one query, one Jellyfin
account/library-selection value, and one local source UUID/index snapshot. Source
loads are independent and explicit; local browsing reads the persisted index and
does not acquire folder access or start indexing. Retirement removes its source's
slot and routing authority. Load and route methods recheck cancellation and
retirement after their final actor await before reporting success. Snapshot reads
filter retired sources after their actor await.

A future UI owner must also own publication lifetime. It must retire or replace
the binding and advance its own presentation token on account retirement, local
Forget/reselection, refreshed-index replacement, query changes and catalog-filter
changes. After every awaited load, route or snapshot read, that owner must verify
its token and current account/local-selection ownership before publishing or
acting. A cached source UUID check cannot atomically cover a selection change
that happens after the cache read. No UI may keep displaying an old binding after
Forget, or publish a late snapshot just because its task completed successfully.
These UI owner checks and app-consumer wiring remain unimplemented; the current
binding is not exposed to existing playback, pin, queue or Handoff consumers.
