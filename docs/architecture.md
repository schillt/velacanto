# Current Velacanto architecture

The sole active app is in NativeFoundation. Version 0.3 preserves build 106's runtime
implementation while replacing the old target. The old architecture remains in
Git history and earlier release documents; it is not a maintained second app.

- FoundationApp owns one saved source, library adapter, player and action owner.
- FoundationLibrary defines neutral items/references and catalog operations;
  FoundationJellyfinLibrary maps official Jellyfin SDK requests through existing
  native URLSession behavior. Providers are not interchangeable runtime plugins.
- FoundationPlayer owns one AVPlayer/current item and an occurrence-based queue.
  Commands select/seek existing native playback. No layered recovery manager.
- SwiftUI pages own cancellable catalog/artwork loading and local presentation.
  Optional sections do not gate healthy audio. Explicit collection commands may
  expand sequential pages before one queue update.
- FoundationCredentials stores one nonsynchronizing Keychain session. Detailed
  FoundationJournal instrumentation is DEBUG-only and uses finite categories.

No new network/ownership mechanism is added for release. Read
[ADR 0012](decisions/0012-foundation-rebuild-and-playback-freeze.md),
[ADR 0013](decisions/0013-rebuilt-03-release.md), [engineering findings](0.3-engineering-record.md)
and [dependencies](0.3-dependencies.md). Provider-neutral/native principles are
retained; speculative future-provider features remain outside the product.
